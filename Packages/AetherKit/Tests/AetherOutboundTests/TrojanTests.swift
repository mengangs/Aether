import AetherFoundation
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import AetherOutbound

private func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

@Suite("SHA-224 (FIPS 180-4)")
struct SHA224Tests {
    @Test(
        "FIPS 180-4 / NIST examples",
        arguments: [
            ("", "d14a028c2a3a2bc9476102bb288234c415a2b01f828ea62ac5b3e42f"),
            ("abc", "23097d223405d8228642a477bda255b32aadbce4bda0b3f7e36c9da7"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "75388b16512776cc5dba5da1fd890150b0c6455cb4f58b1952522525"
            ),
        ])
    func nist(input: String, digest: String) {
        #expect(hexString(SHA224.hash(Array(input.utf8))) == digest)
    }

    @Test("Padding boundaries and long input match Python hashlib")
    func boundaries() {
        let expected: [(Int, String)] = [
            (55, "8991dfba74284e04dc7581c7c3e4068ff6cb7a63733361429834bb56"),
            (56, "2b2cd637c16ad7290bb067ad7d8fd04e204fa43a84366afc7130f4ef"),
            (63, "049e8dd7eab3378ce9f823bfb569e5b270235d4b7f9623606971998f"),
            (64, "c37b88a3522dbf7ac30d1c68ea397ac11d4773571aed01ddab73531e"),
            (65, "114b5fd665736a96585c5d5837d35250aed73c725252cbf7f8b121f6"),
            (119, "762f18c0df65c3d0ea64126c8a6e51db4425e76d4d969ed0f83899be"),
            (120, "d022deb78772a77e8b91d68f90ca1f636e8fe047ae219434ced18eef"),
            (1000, "c182669a7f6629dc7fd8a9198f15af15adbbaeffa1842e854f681357"),
        ]
        for (count, digest) in expected {
            #expect(hexString(SHA224.hash((0..<count).map { UInt8($0 % 251) })) == digest, "length \(count)")
        }
        #expect(
            hexString(SHA224.hash([UInt8](repeating: 0x61, count: 1_000_000)))
                == "20794655980c91d8bbb4c1ea97618a4bf03f42581948b2ee4ee7ad67")
    }
}

/// 测试用 Trojan 服务端（TLS 之后）：校验请求头，CONNECT 回显数据，UDP 把每个数据报原样发回（来源为其目标）。
private final class TestTrojanServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let expectedHash: [UInt8]
    let requests: NIOLockedValueBox<[(command: UInt8, destination: Destination)]>
    private var buffer = ByteBuffer()
    private var command: UInt8?
    private var framing: TrojanUDPFraming

    init(expectedHash: [UInt8], requests: NIOLockedValueBox<[(command: UInt8, destination: Destination)]>) {
        self.expectedHash = expectedHash
        self.requests = requests
        framing = TrojanUDPFraming(passwordHash: expectedHash)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        if command == nil {
            guard buffer.readableBytes >= 59 else { return }
            guard buffer.getBytes(at: buffer.readerIndex, length: 56) == expectedHash,
                buffer.getBytes(at: buffer.readerIndex + 56, length: 2) == [13, 10],
                let cmd = buffer.getInteger(at: buffer.readerIndex + 58, as: UInt8.self)
            else {
                context.close(promise: nil)
                return
            }
            guard case .parsed(let destination, let length) = SOCKSAddress.parse(buffer, at: 59),
                buffer.readableBytes >= 59 + length + 2
            else { return }
            requests.withLockedValue { $0.append((cmd, destination)) }
            buffer.moveReaderIndex(forwardBy: 59 + length + 2)
            command = cmd
        }
        if command == TrojanConnector.commandConnect {
            if buffer.readableBytes > 0 {
                context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
                buffer = ByteBuffer()
            }
            return
        }
        var reply = context.channel.allocator.buffer(capacity: 0)
        var replyFraming = TrojanUDPFraming(passwordHash: [])
        replyFraming.markHeaderSent()
        while let (payload, destination) = try? framing.decode(&buffer) {
            replyFraming.encode(payload, to: destination, into: &reply)
        }
        buffer.discardReadBytes()
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

@Suite("Trojan (06 §8.4)")
struct TrojanTests {
    @Test("The password hash is hex(SHA224) and the header follows the protocol document")
    func header() {
        let connector = TrojanConnector(
            name: "T", server: ProxyServer(host: "trojan.example.com", port: 443), password: "password",
            udpEnabled: false)
        #expect(
            String(decoding: connector.passwordHash, as: UTF8.self)
                == "d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01")
        #expect(connector.server.tls != nil)
        var buffer = ByteBuffer()
        TrojanConnector.header(
            passwordHash: connector.passwordHash, command: 1,
            destination: Destination(host: "www.example.com", port: 443)!,
            into: &buffer)
        let bytes = Array(buffer.readableBytesView)
        #expect(bytes[56...58] == [13, 10, 1])
        #expect(Array(bytes[59...]) == [3, 15] + Array("www.example.com".utf8) + [1, 187, 13, 10])
    }

    @Test("UDP framing round-trips across splits and rejects a bad terminator")
    func udpFraming() throws {
        var encoder = TrojanUDPFraming(passwordHash: Array(repeating: 0x61, count: 56))
        var stream = ByteBuffer()
        let first = Destination.ip(IPAddress("192.0.2.53")!, port: 53)
        let second = Destination(host: "dns.example.net", port: 5353)!
        encoder.encode(ByteBuffer(string: "one"), to: first, into: &stream)
        encoder.encode(ByteBuffer(string: "two"), to: second, into: &stream)
        // 服务端方向没有请求头：去掉 56 + 2 + 1 + 地址 + 2 字节。
        stream.moveReaderIndex(forwardBy: 59 + SOCKSAddress.length(of: first) + 2)
        var decoder = TrojanUDPFraming(passwordHash: [])
        var partial = stream.readSlice(length: 5) ?? ByteBuffer()
        #expect(try decoder.decode(&partial) == nil)
        var rest = partial
        rest.writeBuffer(&stream)
        let one = try #require(try decoder.decode(&rest))
        let two = try #require(try decoder.decode(&rest))
        #expect(String(buffer: one.payload) == "one" && one.source == first)
        #expect(String(buffer: two.payload) == "two" && two.source == second)
        #expect(rest.readableBytes == 0)

        var bad = ByteBuffer()
        SOCKSAddress.write(first, to: &bad)
        bad.writeInteger(UInt16(1))
        bad.writeBytes([0, 0, 0x41])
        #expect(throws: NetworkError.self) { _ = try decoder.decode(&bad) }
    }

    @Test("TCP and UDP through a loopback Trojan server over TLS and WebSocket + TLS", arguments: [false, true])
    func loopback(webSocket: Bool) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let certificates = try TestCertificates.make(dnsNames: ["trojan.example.com"])
        let configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificates.leafDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(certificates.leafKeyPEM.utf8), format: .pem)))
        let sslContext = try NIOSSLContext(configuration: configuration)
        let hash = TrojanConnector(
            name: "T", server: ProxyServer(host: "x", port: 1), password: "secret", udpEnabled: false
        ).passwordHash
        let requests = NIOLockedValueBox<[(command: UInt8, destination: Destination)]>([])
        let port: Int
        let closeServer: @Sendable () async throws -> Void
        if webSocket {
            let ws = try await WebSocketTestServer.start(
                group: group,
                behavior: .forward { TestTrojanServer(expectedHash: hash, requests: requests) }
            ) { channel in
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
            }
            port = ws.server.port
            closeServer = { try await ws.server.close() }
        } else {
            let server = try await LoopbackTCPServer.start(group: group) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                    try channel.pipeline.syncOperations.addHandler(
                        TestTrojanServer(expectedHash: hash, requests: requests))
                }
            }
            port = server.port
            closeServer = { try await server.close() }
        }
        var tls = TLSClientOptions()
        tls.additionalTrustRootsPEM = [certificates.caPEM]
        let connector = TrojanConnector(
            name: "T",
            server: ProxyServer(
                host: "trojan.example.com", port: UInt16(port), tls: tls,
                webSocket: webSocket ? WebSocketClientOptions(path: "/trojan") : nil),
            password: "secret", udpEnabled: true)
        let context = DialContext(
            flowID: FlowID(rawValue: 1), eventLoop: group.next(), deadline: .now() + .seconds(15),
            serverResolver: StaticResolver(table: ["trojan.example.com": [IPAddress("127.0.0.1")!]]),
            logger: Logger(label: "test"))

        let target = Destination(host: "www.example.com", port: 443)!
        let channel = try await connector.connect(to: target, context: context).get()
        let received = Received()
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(received)
            try channel.syncOptions?.setOption(.autoRead, value: true)
            channel.read()
        }.get()
        try await channel.writeAndFlush(ByteBuffer(string: "over trojan"))
        #expect(await Poll.until { received.bytes.withLockedValue { $0.count } == 11 })
        #expect(requests.withLockedValue { $0.first?.command } == 1)
        #expect(requests.withLockedValue { $0.first?.destination } == target)
        try await channel.close()

        let association = try await connector.openUDP(context: context).get()
        let replies = NIOLockedValueBox<[(String, Destination)]>([])
        let dns = Destination.ip(IPAddress("192.0.2.53")!, port: 53)
        try await context.eventLoop.submit {
            association.onDatagram = { payload, source in
                replies.withLockedValue { $0.append((String(buffer: payload), source)) }
            }
            association.send(ByteBuffer(string: "query"), to: dns)
            association.send(ByteBuffer(string: "again"), to: target)
        }.get()
        #expect(await Poll.until { replies.withLockedValue { $0.count } == 2 })
        #expect(replies.withLockedValue { $0.map(\.0) } == ["query", "again"])
        #expect(replies.withLockedValue { $0.map(\.1) } == [dns, target])
        // UDP 的请求头取第一个数据报的目标。
        #expect(requests.withLockedValue { $0.last?.command } == 3)
        #expect(requests.withLockedValue { $0.last?.destination } == dns)
        try await context.eventLoop.submit { association.close() }.get()
        try await closeServer()
        try await group.shutdownGracefully()
    }
}
