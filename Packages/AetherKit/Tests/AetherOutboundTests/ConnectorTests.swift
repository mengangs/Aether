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

/// 固定表解析器：表中的域名解析为给定地址，其余返回空（NOERROR 无记录）。
struct StaticResolver: ServerAddressResolver {
    var table: [String: [IPAddress]]

    func resolve(_ host: String, family: AddressFamily, on eventLoop: any EventLoop) -> EventLoopFuture<[IPAddress]> {
        let addresses = (table[host] ?? []).filter { family == .v4 ? $0.isIPv4 : !$0.isIPv4 }
        return eventLoop.makeSucceededFuture(addresses)
    }
}

private let loopback = IPAddress("127.0.0.1")!

private final class Echo: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

private final class UDPEcho: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

/// 收集 Channel 收到的字节。
private final class Collector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let bytes = NIOLockedValueBox<[UInt8]>([])

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        bytes.withLockedValue { $0.append(contentsOf: buffer.readableBytesView) }
    }

    var text: String { String(decoding: bytes.withLockedValue { $0 }, as: UTF8.self) }
}

private func context(_ loop: any EventLoop, resolver: any ServerAddressResolver = StaticResolver(table: [:]))
    -> DialContext
{
    DialContext(
        flowID: FlowID(rawValue: 1), eventLoop: loop, deadline: .now() + .seconds(15), serverResolver: resolver,
        logger: Logger(label: "test"))
}

/// 在已建立的出站 Channel 上加收集器，发送数据并等待回显。
private func roundTrip(_ channel: any Channel, _ text: String) async throws -> String {
    let collector = Collector()
    try await channel.eventLoop.submit {
        try channel.pipeline.syncOperations.addHandler(collector)
        // 连接器交回的 Channel 不自动读取（见 OutboundConnector）。
        try channel.syncOptions?.setOption(.autoRead, value: true)
        channel.read()
    }.get()
    try await channel.writeAndFlush(ByteBuffer(string: text))
    _ = await Poll.until { collector.text.hasSuffix(text) }
    return collector.text
}

private func echoServer(_ group: any EventLoopGroup) async throws -> LoopbackTCPServer {
    try await LoopbackTCPServer.start(group: group) { channel in
        channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Echo()) }
    }
}

private func closedPort(_ group: any EventLoopGroup) async throws -> Int {
    let probe = try await LoopbackTCPServer.start(group: group) { $0.eventLoop.makeSucceededVoidFuture() }
    let port = probe.port
    try await probe.close()
    return port
}

@Suite("DIRECT connector")
struct DirectConnectorTests {
    @Test("Connects to IP and domain targets and maps refusals to NET-001, missing addresses to NET-011")
    func tcp() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let echo = try await echoServer(group)
        let loop = group.next()
        let direct = DirectConnector(resolver: StaticResolver(table: ["echo.example": [loopback]]))
        let byIP = try await direct.connect(to: .ip(loopback, port: UInt16(echo.port)), context: context(loop)).get()
        #expect(try await roundTrip(byIP, "ip") == "ip")
        let byName = try await direct.connect(
            to: .domain(Hostname("echo.example")!, port: UInt16(echo.port)), context: context(loop)
        ).get()
        #expect(try await roundTrip(byName, "name") == "name")

        let refusedPort = try await closedPort(group)
        await #expect(throws: NetworkError.self) {
            try await direct.connect(to: .ip(loopback, port: UInt16(refusedPort)), context: context(loop)).get()
        }
        do {
            _ = try await direct.connect(to: .ip(loopback, port: UInt16(refusedPort)), context: context(loop)).get()
        } catch let error as NetworkError {
            #expect(error.code == .netConnectionRefused)
        }
        do {
            _ = try await direct.connect(to: .domain(Hostname("nowhere.example")!, port: 80), context: context(loop))
                .get()
            Issue.record("expected failure")
        } catch let error as NetworkError {
            #expect(error.code == .netResolutionFailed)
        }
        try await byIP.close()
        try await byName.close()
        try await echo.close()
        try await group.shutdownGracefully()
    }

    @Test("Without IPv4 the NAT64 synthesizer is consulted for IPv4 targets")
    func nat64() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let echo = try await echoServer(group)
        let calls = NIOLockedValueBox<[IPv4Address]>([])
        // 测试环境没有 NAT64：合成器记录调用并返回 nil（按原地址连接）。
        let nat64 = NAT64Support(
            hasIPv4: { false },
            synthesize: { address, loop in
                calls.withLockedValue { $0.append(address) }
                return loop.makeSucceededFuture(nil)
            })
        let direct = DirectConnector(resolver: StaticResolver(table: ["echo.example": [loopback]]), nat64: nat64)
        let channel = try await direct.connect(
            to: .ip(loopback, port: UInt16(echo.port)), context: context(group.next())
        ).get()
        #expect(try await roundTrip(channel, "x") == "x")
        #expect(calls.withLockedValue { $0 } == [IPv4Address(127, 0, 0, 1)])
        try await channel.close()
        try await echo.close()
        try await group.shutdownGracefully()
    }

    @Test("UDP relays datagrams to IP and domain targets and reports the source")
    func udp() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        let echo = try await DatagramBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(UDPEcho()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = UInt16(echo.localAddress?.port ?? 0)
        let direct = DirectConnector(resolver: StaticResolver(table: ["udp.example": [loopback]]))
        let association = try await direct.openUDP(context: context(loop)).get()
        let received = NIOLockedValueBox<[(String, Destination)]>([])
        try await loop.submit {
            association.onDatagram = { buffer, source in
                received.withLockedValue { $0.append((String(buffer: buffer), source)) }
            }
            association.send(ByteBuffer(string: "one"), to: .ip(loopback, port: port))
            association.send(ByteBuffer(string: "two"), to: .domain(Hostname("udp.example")!, port: port))
        }.get()
        #expect(await Poll.until { received.withLockedValue { $0.count } == 2 })
        let messages = received.withLockedValue { $0 }
        #expect(Set(messages.map(\.0)) == ["one", "two"])
        #expect(messages.allSatisfy { $0.1 == .ip(loopback, port: port) })
        try await loop.submit { association.close() }.get()
        try await association.closeFuture.get()
        try await echo.close()
        try await group.shutdownGracefully()
    }
}

// MARK: - HTTP CONNECT

/// 测试用 HTTP CONNECT 代理：要求 `Basic dXNlcjpwYXNz`（user:pass），`forbidden.example` 回 403，
/// 成功响应后立即附带 `early` 以验证握手后数据的转交。
private final class TestConnectProxyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var buffer = ByteBuffer()
    private var connected = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !connected else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        let text = String(buffer: buffer)
        guard let end = text.range(of: "\r\n\r\n") else { return }
        connected = true
        let header = String(text[..<end.lowerBound])
        let lines = header.components(separatedBy: "\r\n")
        let target = lines[0].split(separator: " ")[1]
        guard lines.contains("Proxy-Authorization: Basic dXNlcjpwYXNz") else {
            reply(
                context: context, "HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n", close: true
            )
            return
        }
        if target.hasPrefix("forbidden.example") {
            reply(context: context, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n", close: true)
            return
        }
        let port = Int(target.split(separator: ":").last ?? "") ?? 0
        let inbound = context.channel
        ClientBootstrap(group: context.eventLoop).connect(host: "127.0.0.1", port: port).whenComplete { result in
            guard case .success(let outbound) = result else {
                inbound.close(promise: nil)
                return
            }
            // 先装好转发再回复，客户端收到回复后立即发送的数据才不会丢。
            try? inbound.pipeline.syncOperations.addHandler(Forward(to: outbound))
            try? outbound.pipeline.syncOperations.addHandler(Forward(to: inbound))
            inbound.writeAndFlush(
                ByteBuffer(string: "HTTP/1.1 200 Connection established\r\nVia: test\r\n\r\nearly"),
                promise: nil)
        }
    }

    private func reply(context: ChannelHandlerContext, _ text: String, close: Bool) {
        let loopBound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: text))).whenComplete { _ in
            if close { loopBound.value.close(promise: nil) }
        }
    }
}

private final class Forward: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    let peer: any Channel

    init(to peer: any Channel) {
        self.peer = peer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        peer.writeAndFlush(unwrapInboundIn(data), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer.close(promise: nil)
    }
}

@Suite("HTTP CONNECT connector")
struct HTTPConnectConnectorTests {
    @Test("Authenticated CONNECT tunnels bytes and replays data sent right after the response")
    func tunnel() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let echo = try await echoServer(group)
        let proxy = try await LoopbackTCPServer.start(group: group) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(TestConnectProxyHandler())
            }
        }
        let server = ProxyServer(host: "127.0.0.1", port: UInt16(proxy.port))
        let connector = HTTPConnectConnector(name: "HTTP", server: server, username: "user", password: "pass")
        #expect(connector.authorization == "Basic dXNlcjpwYXNz")
        let channel = try await connector.connect(
            to: .domain(Hostname("echo.example")!, port: UInt16(echo.port)), context: context(group.next())
        ).get()
        let echoed = try await roundTrip(channel, "ping")
        #expect(echoed == "earlyping")
        try await channel.close()

        let wrongPassword = HTTPConnectConnector(name: "HTTP", server: server, username: "user", password: "nope")
        do {
            _ = try await wrongPassword.connect(to: .ip(loopback, port: 80), context: context(group.next())).get()
            Issue.record("expected 407")
        } catch let error as NetworkError {
            #expect(error.code == .netProxyAuthFailed)
        }
        do {
            _ = try await connector.connect(
                to: .domain(Hostname("forbidden.example")!, port: 80), context: context(group.next())
            ).get()
            Issue.record("expected 403")
        } catch let error as NetworkError {
            #expect(error.code == .netProxyHandshakeFailed)
            #expect(error.details.contains("403"))
        }
        try await proxy.close()
        try await echo.close()
        try await group.shutdownGracefully()
    }
}

// MARK: - TLS

private final class TLSEchoServer: Sendable {
    let server: LoopbackTCPServer
    let certificates: TestCertificates

    init(server: LoopbackTCPServer, certificates: TestCertificates) {
        self.server = server
        self.certificates = certificates
    }

    static func start(group: any EventLoopGroup) async throws -> TLSEchoServer {
        let certificates = try TestCertificates.make(dnsNames: ["tls.example.com"])
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificates.leafDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(certificates.leafKeyPEM.utf8), format: .pem)))
        let sslContext = try NIOSSLContext(configuration: configuration)
        // 不允许半关闭：收到 close_notify 即回应并关闭，客户端关闭时不必等待超时。
        let server = try await LoopbackTCPServer.start(
            group: group, childOptions: { $0.childChannelOption(.allowRemoteHalfClosure, value: false) },
            childInitializer: { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                    try channel.pipeline.syncOperations.addHandler(Echo())
                }
            })
        return TLSEchoServer(server: server, certificates: certificates)
    }
}

@Suite("TLS transport")
struct TLSTransportTests {
    private func dial(_ tls: TLSClientOptions, server: TLSEchoServer, group: any EventLoopGroup) async throws
        -> any Channel
    {
        let proxy = ProxyServer(host: "tls.example.com", port: UInt16(server.server.port), tls: tls)
        return try await proxy.dial(
            context: context(group.next(), resolver: StaticResolver(table: ["tls.example.com": [loopback]]))
        ).get()
    }

    private func expectTLSError(
        _ code: AetherErrorCode, _ tls: TLSClientOptions, server: TLSEchoServer, group: any EventLoopGroup
    )
        async
    {
        do {
            let channel = try await dial(tls, server: server, group: group)
            try? await channel.close()
            Issue.record("expected \(code)")
        } catch let error as TLSError {
            #expect(error.code == code, "\(error.details)")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test("Full verification, skip-cert-verify, fingerprint pinning and their failures")
    func verificationModes() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await TLSEchoServer.start(group: group)

        var trusted = TLSClientOptions()
        trusted.additionalTrustRootsPEM = [server.certificates.caPEM]
        let verified = try await dial(trusted, server: server, group: group)
        #expect(try await roundTrip(verified, "secure") == "secure")
        try await verified.close()

        // 系统信任根不认识测试 CA。
        await expectTLSError(.tlsCertificateInvalid, TLSClientOptions(), server: server, group: group)

        var wrongName = trusted
        wrongName.serverName = .custom("other.example.com")
        await expectTLSError(.tlsHostnameMismatch, wrongName, server: server, group: group)

        var skip = TLSClientOptions()
        skip.skipCertificateVerification = true
        let skipped = try await dial(skip, server: server, group: group)
        #expect(try await roundTrip(skipped, "skip") == "skip")
        try await skipped.close()

        var pinned = TLSClientOptions()
        pinned.certificateFingerprintSHA256 = Array(SHA256.hash(data: server.certificates.leafDER))
        let pinnedChannel = try await dial(pinned, server: server, group: group)
        #expect(try await roundTrip(pinnedChannel, "pin") == "pin")
        try await pinnedChannel.close()

        var wrongPin = TLSClientOptions()
        wrongPin.certificateFingerprintSHA256 = [UInt8](repeating: 0xAB, count: 32)
        await expectTLSError(.tlsFingerprintMismatch, wrongPin, server: server, group: group)

        try await server.server.close()
        try await group.shutdownGracefully()
    }

    @Test("SNI follows the option")
    func serverName() {
        var options = TLSClientOptions()
        #expect(options.effectiveServerName(serverHost: "proxy.example.com") == "proxy.example.com")
        #expect(options.effectiveServerName(serverHost: "192.0.2.1") == nil)
        options.serverName = .custom("cdn.example.net")
        #expect(options.effectiveServerName(serverHost: "192.0.2.1") == "cdn.example.net")
        options.serverName = .disabled
        #expect(options.effectiveServerName(serverHost: "proxy.example.com") == nil)
    }
}
