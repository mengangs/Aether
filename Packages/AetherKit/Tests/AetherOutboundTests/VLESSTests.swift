import AetherFoundation
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import AetherOutbound

/// 测试用 VLESS 服务端（TLS 之后）：解析请求头，回复响应头（带 `addons` 字节以测试剥离），
/// TCP 回显，UDP 回显长度前缀的数据报。
private final class TestVLESSServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let uuid: [UInt8]
    let requests: NIOLockedValueBox<[(command: UInt8, destination: Destination)]>
    private var buffer = ByteBuffer()
    private var command: UInt8?

    init(uuid: [UInt8], requests: NIOLockedValueBox<[(command: UInt8, destination: Destination)]>) {
        self.uuid = uuid
        self.requests = requests
    }

    /// 解析 端口 ‖ 地址类型 ‖ 地址（相对 readerIndex 的 offset 处）。
    static func address(_ buffer: ByteBuffer, at offset: Int) -> (Destination, Int)? {
        let base = buffer.readerIndex + offset
        guard let port = buffer.getInteger(at: base, as: UInt16.self),
            let type = buffer.getInteger(at: base + 2, as: UInt8.self)
        else { return nil }
        switch type {
        case 1:
            guard let bytes = buffer.getBytes(at: base + 3, length: 4), let v4 = IPv4Address(bytes: bytes) else {
                return nil
            }
            return (.ip(.v4(v4), port: port), 7)
        case 2:
            guard let length = buffer.getInteger(at: base + 3, as: UInt8.self),
                let name = buffer.getString(at: base + 4, length: Int(length)),
                let destination = Destination(host: name, port: port)
            else { return nil }
            return (destination, 4 + Int(length))
        case 3:
            guard let bytes = buffer.getBytes(at: base + 3, length: 16), let v6 = IPv6Address(bytes: bytes) else {
                return nil
            }
            return (.ip(.v6(v6), port: port), 19)
        default:
            return nil
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        var reply = context.channel.allocator.buffer(capacity: 0)
        if command == nil {
            guard buffer.readableBytes >= 19 else { return }
            guard buffer.getInteger(at: buffer.readerIndex, as: UInt8.self) == 0,
                buffer.getBytes(at: buffer.readerIndex + 1, length: 16) == uuid,
                buffer.getInteger(at: buffer.readerIndex + 17, as: UInt8.self) == 0,
                let cmd = buffer.getInteger(at: buffer.readerIndex + 18, as: UInt8.self)
            else {
                context.close(promise: nil)
                return
            }
            guard let (destination, length) = Self.address(buffer, at: 19) else { return }
            requests.withLockedValue { $0.append((cmd, destination)) }
            buffer.moveReaderIndex(forwardBy: 19 + length)
            command = cmd
            // 响应头：版本 0、2 字节附加信息。
            reply.writeBytes([0, 2, 0xAA, 0xBB])
        }
        if command == VLESSConnector.commandTCP {
            reply.writeBuffer(&buffer)
        } else {
            let framing = LengthPrefixedFraming(destination: .ip(IPAddress("0.0.0.0")!, port: 0))
            while let (payload, _) = try? framing.decode(&buffer) {
                framing.encode(payload, to: framing.destination, into: &reply)
            }
            buffer.discardReadBytes()
        }
        if reply.readableBytes > 0 {
            context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
        }
    }
}

private final class Received: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    let bytes = NIOLockedValueBox<[UInt8]>([])

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        bytes.withLockedValue { $0.append(contentsOf: buffer.readableBytesView) }
    }
}

@Suite("VLESS (06 §8.4)")
struct VLESSTests {
    static let uuidText = "b831381d-6324-4d53-ad4f-8cda48b30811"
    static let uuidBytes: [UInt8] = [
        0xb8, 0x31, 0x38, 0x1d, 0x63, 0x24, 0x4d, 0x53, 0xad, 0x4f, 0x8c, 0xda, 0x48, 0xb3, 0x08, 0x11,
    ]

    @Test("Request header layout: version, UUID, no addons, command, port, VLESS address types")
    func header() throws {
        let connector = try #require(
            VLESSConnector(
                name: "V", server: ProxyServer(host: "vless.example.com", port: 443), uuid: Self.uuidText,
                udpEnabled: false))
        #expect(connector.uuid == Self.uuidBytes)
        #expect(
            VLESSConnector(name: "V", server: ProxyServer(host: "x", port: 1), uuid: "nope", udpEnabled: false) == nil)
        let domain: [UInt8] = [1, 187, 2, 15] + Array("www.example.com".utf8)
        var v6: [UInt8] = [0x20, 0xFB, 3, 0x20, 0x01, 0x0d, 0xb8]
        v6 += [UInt8](repeating: 0, count: 11)
        v6.append(1)
        let cases: [(Destination, [UInt8])] = [
            (.ip(IPAddress("192.0.2.1")!, port: 80), [0, 80, 1, 192, 0, 2, 1]),
            (Destination(host: "www.example.com", port: 443)!, domain),
            (.ip(IPAddress("2001:db8::1")!, port: 8443), v6),
        ]
        for (destination, address) in cases {
            var buffer = ByteBuffer()
            VLESSConnector.header(uuid: Self.uuidBytes, command: 1, destination: destination, into: &buffer)
            let expected: [UInt8] = [0] + Self.uuidBytes + [0, 1] + address
            #expect(Array(buffer.readableBytesView) == expected, "\(destination)")
        }
    }

    @Test("TCP strips the response header with addons; UDP opens one stream per destination", arguments: [false, true])
    func loopback(webSocket: Bool) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let certificates = try TestCertificates.make(dnsNames: ["vless.example.com"])
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificates.leafDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(certificates.leafKeyPEM.utf8), format: .pem)))
        let sslContext = try NIOSSLContext(configuration: configuration)
        let requests = NIOLockedValueBox<[(command: UInt8, destination: Destination)]>([])
        let uuid = Self.uuidBytes
        let port: Int
        let closeServer: @Sendable () async throws -> Void
        if webSocket {
            let ws = try await WebSocketTestServer.start(
                group: group, behavior: .forward { TestVLESSServer(uuid: uuid, requests: requests) }
            ) { channel in
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
            }
            port = ws.server.port
            closeServer = { try await ws.server.close() }
        } else {
            let server = try await LoopbackTCPServer.start(group: group) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                    try channel.pipeline.syncOperations.addHandler(TestVLESSServer(uuid: uuid, requests: requests))
                }
            }
            port = server.port
            closeServer = { try await server.close() }
        }
        var tls = TLSClientOptions()
        tls.additionalTrustRootsPEM = [certificates.caPEM]
        let connector = try #require(
            VLESSConnector(
                name: "V",
                server: ProxyServer(
                    host: "vless.example.com", port: UInt16(port), tls: tls,
                    webSocket: webSocket ? WebSocketClientOptions(path: "/vless") : nil),
                uuid: Self.uuidText, udpEnabled: true))
        let context = DialContext(
            flowID: FlowID(rawValue: 1), eventLoop: group.next(), deadline: .now() + .seconds(15),
            serverResolver: StaticResolver(table: ["vless.example.com": [IPAddress("127.0.0.1")!]]),
            logger: Logger(label: "test"))

        let target = Destination(host: "www.example.com", port: 443)!
        let channel = try await connector.connect(to: target, context: context).get()
        let received = Received()
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(received)
            try channel.syncOptions?.setOption(.autoRead, value: true)
            channel.read()
        }.get()
        try await channel.writeAndFlush(ByteBuffer(string: "over vless"))
        #expect(await Poll.until { received.bytes.withLockedValue { $0.count } >= 10 })
        #expect(String(decoding: received.bytes.withLockedValue { $0 }, as: UTF8.self) == "over vless")
        try await channel.close()

        let association = try await connector.openUDP(context: context).get()
        let replies = NIOLockedValueBox<[(String, Destination)]>([])
        let dns = Destination.ip(IPAddress("192.0.2.53")!, port: 53)
        try await context.eventLoop.submit {
            association.onDatagram = { payload, source in
                replies.withLockedValue { $0.append((String(buffer: payload), source)) }
            }
            association.send(ByteBuffer(string: "query"), to: dns)
            association.send(ByteBuffer(string: "query-2"), to: dns)
            association.send(ByteBuffer(string: "other"), to: target)
        }.get()
        #expect(await Poll.until { replies.withLockedValue { $0.count } == 3 })
        let got = replies.withLockedValue { $0 }
        #expect(got.filter { $0.1 == dns }.map(\.0) == ["query", "query-2"])
        #expect(got.contains { $0.0 == "other" && $0.1 == target })
        // TCP 一条、UDP 每个目标一条。
        let commands = requests.withLockedValue { $0 }
        let udpTargets: Set<Destination> = Set(commands.filter { $0.command == 2 }.map(\.destination))
        let expectedTargets: Set<Destination> = [dns, target]
        #expect(udpTargets == expectedTargets)
        try await context.eventLoop.submit { association.close() }.get()
        try await closeServer()
        try await group.shutdownGracefully()
    }

    @Test("Per-destination associations are capped, queue while opening and drop when opening fails")
    func perDestinationLimits() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        final class Fake: OutboundUDPAssociation, @unchecked Sendable {
            var onDatagram: ((ByteBuffer, Destination) -> Void)?
            let promise: EventLoopPromise<Void>
            var sent: [String] = []
            var closeFuture: EventLoopFuture<Void> { promise.futureResult }
            init(_ loop: any EventLoop) { promise = loop.makePromise() }
            func send(_ payload: ByteBuffer, to destination: Destination) { sent.append(String(buffer: payload)) }
            func close() { promise.succeed(()) }
        }
        let opened = NIOLockedValueBox<[Destination: Fake]>([:])
        let pendingOpens = NIOLockedValueBox<[Destination: EventLoopPromise<any OutboundUDPAssociation>]>([:])
        let association = try await loop.submit {
            PerDestinationUDPAssociation(eventLoop: loop, limit: 2, pendingLimit: 2) { destination in
                let promise = loop.makePromise(of: (any OutboundUDPAssociation).self)
                pendingOpens.withLockedValue { $0[destination] = promise }
                return promise.futureResult
            }
        }.get()
        let a = Destination.ip(IPAddress("192.0.2.1")!, port: 1)
        let b = Destination.ip(IPAddress("192.0.2.2")!, port: 1)
        let c = Destination.ip(IPAddress("192.0.2.3")!, port: 1)
        try await loop.submit {
            for text in ["1", "2", "3"] { association.send(ByteBuffer(string: text), to: a) }
            let fake = Fake(loop)
            opened.withLockedValue { $0[a] = fake }
            pendingOpens.withLockedValue { $0[a] }?.succeed(fake)
        }.get()
        // 队列上限 2：最旧的 "1" 被丢弃。
        #expect(opened.withLockedValue { $0[a]?.sent } == ["2", "3"])
        try await loop.submit {
            association.send(ByteBuffer(string: "b"), to: b)
            pendingOpens.withLockedValue { $0[b] }?.fail(NetworkError(.netConnectionRefused, "refused"))
            association.send(ByteBuffer(string: "c"), to: c)
            association.send(ByteBuffer(string: "a2"), to: a)
        }.get()
        #expect(association.dropped == 2)
        // b 失败后不再占位；c 正在建立，a 仍在用。
        #expect(opened.withLockedValue { $0[a]?.sent } == ["2", "3", "a2"])
        try await loop.submit { association.close() }.get()
        try await association.closeFuture.get()
        try await group.shutdownGracefully()
    }
}
