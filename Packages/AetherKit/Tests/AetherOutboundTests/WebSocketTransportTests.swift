import AetherFoundation
import AetherTestSupport
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import AetherOutbound

/// 收集出站 Channel 收到的字节、错误与关闭。
private final class StreamCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let state = NIOLockedValueBox<(bytes: [UInt8], errors: [any Error], closed: Bool)>(([], [], false))

    var bytes: [UInt8] { state.withLockedValue { $0.bytes } }
    var errors: [any Error] { state.withLockedValue { $0.errors } }
    var isClosed: Bool { state.withLockedValue { $0.closed } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        state.withLockedValue { $0.bytes.append(contentsOf: buffer.readableBytesView) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        state.withLockedValue { $0.errors.append(error) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.withLockedValue { $0.closed = true }
        context.fireChannelInactive()
    }
}

private func dialContext(_ loop: any EventLoop, table: [String: [IPAddress]] = [:]) -> DialContext {
    DialContext(
        flowID: FlowID(rawValue: 1), eventLoop: loop, deadline: .now() + .seconds(15),
        serverResolver: StaticResolver(table: table), logger: Logger(label: "test"))
}

/// 装上收集器并开始读取（连接器交回的 Channel 不自动读取）。
private func attach(_ channel: any Channel) async throws -> StreamCollector {
    let collector = StreamCollector()
    try await channel.eventLoop.submit {
        try channel.pipeline.syncOperations.addHandler(collector)
        try channel.syncOptions?.setOption(.autoRead, value: true)
        channel.read()
    }.get()
    return collector
}

private func pattern(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8($0 % 251) }
}

/// 只回复固定内容的升级服务：`101` 的 Accept 按请求计算（`validAccept = false` 时故意写错），
/// 并在同一次写入中紧跟 `trailing` 字节。
private final class RawUpgradeResponder: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let validAccept: Bool
    let trailing: [UInt8]

    init(validAccept: Bool, trailing: [UInt8]) {
        self.validAccept = validAccept
        self.trailing = trailing
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let request = String(buffer: unwrapInboundIn(data))
        guard request.contains("\r\n\r\n") else { return }
        let key =
            request.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }?
            .dropFirst("sec-websocket-key:".count).trimmingCharacters(in: .whitespaces) ?? ""
        let accept = validAccept ? WebSocketTransport.acceptValue(forKey: key) : "AAAAAAAAAAAAAAAAAAAAAAAAAAA="
        var response = context.channel.allocator.buffer(
            string: "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: \(accept)\r\n\r\n")
        response.writeBytes(trailing)
        context.writeAndFlush(wrapOutboundOut(response), promise: nil)
    }
}

@Suite("WebSocket transport (06 §8.5)")
struct WebSocketTransportTests {
    @Test("Upgrades with the configured path and headers and echoes payloads split into ≤ 16 KiB frames")
    func echo() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let ws = try await WebSocketTestServer.start(group: group)
        let options = WebSocketClientOptions(
            path: "ray?ed=0",
            headers: [
                .init(name: "Host", value: "cdn.example.com"), .init(name: "X-Trace", value: "a\r\nInjected: 1"),
                .init(name: "Sec-WebSocket-Version", value: "8"),
            ])
        let server = ProxyServer(host: "ws.example.com", port: UInt16(ws.server.port), webSocket: options)
        let channel = try await server.dial(
            context: dialContext(group.next(), table: ["ws.example.com": [IPAddress("127.0.0.1")!]])
        ).get()
        let collector = try await attach(channel)
        let payload = pattern(300_000)
        try await channel.writeAndFlush(ByteBuffer(bytes: payload))
        #expect(await Poll.until { collector.bytes.count >= payload.count })
        #expect(collector.bytes == payload)
        #expect(ws.largestClientFrame <= WebSocketTransport.maxOutgoingFramePayload)

        let request = try #require(ws.requests.first)
        #expect(request.uri == "/ray?ed=0")
        #expect(request.headers["host"] == "cdn.example.com")
        #expect(request.headers["x-trace"] == "aInjected: 1")
        #expect(request.headers["injected"] == nil)
        #expect(request.headers["sec-websocket-version"] == "13")

        // 完全关闭时先发送 close 帧。
        try await channel.close()
        #expect(await Poll.until { ws.clientCloseCount == 1 })
        try await ws.server.close()
        try await group.shutdownGracefully()
    }

    @Test("WebSocket over TLS sends the SNI as Host and verifies the certificate")
    func overTLS() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let certificates = try TestCertificates.make(dnsNames: ["cdn.example.net"])
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificates.leafDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(certificates.leafKeyPEM.utf8), format: .pem)))
        let sslContext = try NIOSSLContext(configuration: configuration)
        let ws = try await WebSocketTestServer.start(group: group) { channel in
            try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
        }
        var tls = TLSClientOptions()
        tls.serverName = .custom("cdn.example.net")
        tls.additionalTrustRootsPEM = [certificates.caPEM]
        let server = ProxyServer(
            host: "127.0.0.1", port: UInt16(ws.server.port), tls: tls, webSocket: WebSocketClientOptions(path: "/ws"))
        let channel = try await server.dial(context: dialContext(group.next())).get()
        let collector = try await attach(channel)
        try await channel.writeAndFlush(ByteBuffer(string: "over tls"))
        #expect(await Poll.until { collector.bytes.count == 8 })
        #expect(String(decoding: collector.bytes, as: UTF8.self) == "over tls")
        #expect(ws.requests.first?.headers["host"] == "cdn.example.net")
        try await channel.close()
        try await ws.server.close()
        try await group.shutdownGracefully()
    }

    @Test("Ping is answered with pong; a server close ends the connection; output half-close is ignored")
    func controlFrames() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let ping = try await WebSocketTestServer.start(group: group, behavior: .pingThenEcho)
        let channel = try await ProxyServer(
            host: "127.0.0.1", port: UInt16(ping.server.port), webSocket: WebSocketClientOptions()
        ).dial(context: dialContext(group.next())).get()
        let collector = try await attach(channel)
        #expect(await Poll.until { ping.pongCount == 1 })
        // 输出方向的关闭被忽略：之后仍可收发。
        try await channel.close(mode: .output)
        try await channel.writeAndFlush(ByteBuffer(string: "still open"))
        #expect(await Poll.until { collector.bytes.count == 10 })
        #expect(!collector.isClosed)
        try await channel.close()
        try await ping.server.close()

        let closing = try await WebSocketTestServer.start(group: group, behavior: .closeAfterFirstEcho)
        let second = try await ProxyServer(
            host: "127.0.0.1", port: UInt16(closing.server.port), webSocket: WebSocketClientOptions()
        ).dial(context: dialContext(group.next())).get()
        let secondCollector = try await attach(second)
        try await second.writeAndFlush(ByteBuffer(string: "bye"))
        #expect(await Poll.until { secondCollector.isClosed })
        #expect(String(decoding: secondCollector.bytes, as: UTF8.self) == "bye")
        // 客户端回复了 close 帧。
        #expect(await Poll.until { closing.clientCloseCount == 1 })
        try await closing.server.close()
        try await group.shutdownGracefully()
    }

    @Test("Frames up to 128 KiB are delivered; a larger frame closes the connection with NET-032")
    func incomingFrameLimit() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        for (size, accepted) in [(100_000, true), (WebSocketTransport.maxIncomingFrameSize + 1, false)] {
            let ws = try await WebSocketTestServer.start(group: group, behavior: .sendFrame(size: size))
            let channel = try await ProxyServer(
                host: "127.0.0.1", port: UInt16(ws.server.port), webSocket: WebSocketClientOptions()
            ).dial(context: dialContext(group.next())).get()
            let collector = try await attach(channel)
            if accepted {
                #expect(await Poll.until { collector.bytes.count == size })
                try await channel.close()
            } else {
                #expect(await Poll.until { collector.isClosed })
                #expect(collector.bytes.isEmpty)
                let codes = collector.errors.compactMap { ($0 as? NetworkError)?.code }
                #expect(codes.contains(.netProtocolError))
            }
            try await ws.server.close()
        }
        try await group.shutdownGracefully()
    }

    @Test("A non-101 answer fails with NET-030, a wrong Accept with NET-032; bytes after 101 are replayed")
    func upgradeOutcomes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let rejecting = try await WebSocketTestServer.start(group: group, behavior: .reject(status: 403))
        do {
            _ = try await ProxyServer(
                host: "127.0.0.1", port: UInt16(rejecting.server.port), webSocket: WebSocketClientOptions()
            ).dial(context: dialContext(group.next())).get()
            Issue.record("expected NET-030")
        } catch let error as NetworkError {
            #expect(error.code == .netProxyHandshakeFailed)
            #expect(error.debugDetails.contains("403"))
        }
        try await rejecting.server.close()

        // 服务端在 101 之后同一次写入中紧跟一个二进制帧 "hello"（未加掩码）。
        let greeting: [UInt8] = [0x82, 0x05] + Array("hello".utf8)
        for valid in [false, true] {
            let raw = try await LoopbackTCPServer.start(group: group) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        RawUpgradeResponder(validAccept: valid, trailing: greeting))
                }
            }
            let dial = ProxyServer(host: "127.0.0.1", port: UInt16(raw.port), webSocket: WebSocketClientOptions())
                .dial(context: dialContext(group.next()))
            if valid {
                let channel = try await dial.get()
                let collector = try await attach(channel)
                #expect(await Poll.until { collector.bytes.count == 5 })
                #expect(String(decoding: collector.bytes, as: UTF8.self) == "hello")
                try await channel.close()
            } else {
                do {
                    _ = try await dial.get()
                    Issue.record("expected NET-032")
                } catch let error as NetworkError {
                    #expect(error.code == .netProtocolError)
                }
            }
            try await raw.close()
        }
        try await group.shutdownGracefully()
    }

    @Test("Host header precedence: ws-headers Host, custom SNI, then the server with a non-default port")
    func hostHeader() {
        let plain = WebSocketClientOptions()
        #expect(plain.hostHeader(serverHost: "proxy.example.com", port: 80, tls: nil) == "proxy.example.com")
        #expect(plain.hostHeader(serverHost: "proxy.example.com", port: 8080, tls: nil) == "proxy.example.com:8080")
        #expect(
            plain.hostHeader(serverHost: "proxy.example.com", port: 443, tls: TLSClientOptions()) == "proxy.example.com"
        )
        #expect(
            plain.hostHeader(serverHost: "2001:db8::1", port: 8443, tls: TLSClientOptions()) == "[2001:db8::1]:8443")
        var sni = TLSClientOptions()
        sni.serverName = .custom("cdn.example.net")
        #expect(plain.hostHeader(serverHost: "192.0.2.1", port: 443, tls: sni) == "cdn.example.net")
        let explicit = WebSocketClientOptions(headers: [.init(name: "host", value: "front.example.org")])
        #expect(explicit.hostHeader(serverHost: "192.0.2.1", port: 443, tls: sni) == "front.example.org")
        #expect(WebSocketClientOptions(path: "ray").requestPath == "/ray")
        // RFC 6455 §1.3 的示例。
        #expect(WebSocketTransport.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }
}
