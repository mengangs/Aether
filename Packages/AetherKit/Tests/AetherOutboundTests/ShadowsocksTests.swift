import AetherFoundation
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import AetherOutbound

/// Shadowsocks AEAD 的测试向量（Tests/Fixtures/vectors/shadowsocks/aead.json，由同目录的 generate.py 用
/// Python `cryptography` 独立生成）。
struct ShadowsocksVectors: Decodable {
    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let method: String
        let masterKey: String
        let clientSalt: String
        let serverSalt: String
        let request: String
        let response: String
        let udpRequest: String
        let udpResponse: String

        var testDescription: String { method }
        var aead: ShadowsocksAEADMethod { ShadowsocksAEADMethod(rawValue: method) ?? .aes128GCM }
    }

    let password: String
    let cases: [Case]

    static let loaded: ShadowsocksVectors = {
        do {
            return try JSONDecoder().decode(
                ShadowsocksVectors.self, from: Fixtures.data("vectors/shadowsocks/aead.json"))
        } catch {
            Issue.record("vectors: \(error)")
            return ShadowsocksVectors(password: "", cases: [])
        }
    }()
}

private func hex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
        index = next
    }
    return bytes
}

private let testDestination = Destination(host: "www.example.com", port: 443)!

@Suite("Shadowsocks AEAD (06 §8.4)")
struct ShadowsocksVectorTests {
    @Test("EVP_BytesToKey matches OpenSSL (`openssl enc -md md5 -nosalt -P`)")
    func bytesToKey() {
        let key = ShadowsocksKDF.bytesToKey(password: Array("aether-test-password".utf8), length: 32)
        #expect(key == hex("4dcf486f41b7223b9080587b54a4e3252d7606fb1e1abc2ca98d5214145d4428"))
        #expect(
            ShadowsocksKDF.bytesToKey(password: Array("aether-test-password".utf8), length: 16) == Array(key.prefix(16))
        )
    }

    @Test("Nonce counter is little-endian and carries")
    func nonce() {
        var counter = AEADNonceCounter()
        #expect(counter.next() == [UInt8](repeating: 0, count: 12))
        #expect(counter.next() == [1] + [UInt8](repeating: 0, count: 11))
        for _ in 2..<256 { _ = counter.next() }
        #expect(counter.next() == [0, 1] + [UInt8](repeating: 0, count: 10))
    }

    @Test(
        "TCP stream matches the vectors; responses decode across arbitrary splits; tampering fails",
        arguments: ShadowsocksVectors.loaded.cases)
    func tcp(_ vector: ShadowsocksVectors.Case) throws {
        let master = ShadowsocksKDF.bytesToKey(
            password: Array(ShadowsocksVectors.loaded.password.utf8), length: vector.aead.keyLength)
        #expect(master == hex(vector.masterKey))

        var encoder = ShadowsocksStreamEncoder(method: vector.aead, masterKey: master, salt: hex(vector.clientSalt))
        var output = ByteBuffer()
        var header = ByteBuffer()
        SOCKSAddress.write(testDestination, to: &header)
        try encoder.encode(header, into: &output)
        try encoder.encode(ByteBuffer(string: "hello"), into: &output)
        #expect(Array(output.readableBytesView) == hex(vector.request))

        let response = hex(vector.response)
        let expected = Array("world".utf8) + (0..<0x3FFF).map { UInt8($0 % 251) }
        for split in [1, 7, 33, response.count / 2] {
            var decoder = ShadowsocksStreamDecoder(method: vector.aead, masterKey: master)
            var plain = ByteBuffer()
            var first = ByteBuffer(bytes: response[..<split])
            var rest = ByteBuffer(bytes: response[split...])
            try decoder.decode(&first, into: &plain)
            try decoder.decode(&rest, into: &plain)
            #expect(Array(plain.readableBytesView) == expected, "split at \(split)")
        }

        var tampered = response
        tampered[tampered.count - 1] ^= 0x01
        var decoder = ShadowsocksStreamDecoder(method: vector.aead, masterKey: master)
        var input = ByteBuffer(bytes: tampered)
        var plain = ByteBuffer()
        #expect(throws: ShadowsocksStreamDecoder.Failure.self) { try decoder.decode(&input, into: &plain) }
    }

    @Test("UDP packets match the vectors and tampered packets are rejected", arguments: ShadowsocksVectors.loaded.cases)
    func udp(_ vector: ShadowsocksVectors.Case) throws {
        let master = ShadowsocksKDF.bytesToKey(
            password: Array(ShadowsocksVectors.loaded.password.utf8), length: vector.aead.keyLength)
        let codec = ShadowsocksUDPCodec(method: vector.aead, masterKey: master)
        let allocator = ByteBufferAllocator()
        let packet = try codec.seal(
            ByteBuffer(string: "query"), destination: .ip(IPAddress("192.0.2.53")!, port: 53),
            salt: hex(vector.clientSalt), allocator: allocator)
        #expect(Array(packet.readableBytesView) == hex(vector.udpRequest))

        let opened = try #require(codec.open(ByteBuffer(bytes: hex(vector.udpResponse)), allocator: allocator))
        #expect(opened.source == .ip(IPAddress("198.51.100.7")!, port: 5353))
        #expect(String(buffer: opened.payload) == "answer")

        var tampered = hex(vector.udpResponse)
        tampered[tampered.count - 1] ^= 0x80
        #expect(codec.open(ByteBuffer(bytes: tampered), allocator: allocator) == nil)
    }
}

// MARK: - 回环服务端

/// 测试用 Shadowsocks 服务端（同一套编解码的服务端方向）：解出目标地址后回显数据；
/// `obfs` 时先剥掉 simple-obfs 的请求头并回复 101；`corruptResponses` 时回复无法认证的字节。
private final class TestShadowsocksServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let method: ShadowsocksAEADMethod
    let master: [UInt8]
    let obfs: Bool
    let corruptResponses: Bool
    let destinations: NIOLockedValueBox<[Destination]>
    let obfsRequests: NIOLockedValueBox<[String]>

    private var decoder: ShadowsocksStreamDecoder
    private var encoder: ShadowsocksStreamEncoder
    private var plain = ByteBuffer()
    private var parsedAddress = false
    private var obfsHeader: ByteBuffer? = ByteBuffer()

    init(
        method: ShadowsocksAEADMethod, master: [UInt8], obfs: Bool, corruptResponses: Bool,
        destinations: NIOLockedValueBox<[Destination]>, obfsRequests: NIOLockedValueBox<[String]>
    ) {
        self.method = method
        self.master = master
        self.obfs = obfs
        self.corruptResponses = corruptResponses
        self.destinations = destinations
        self.obfsRequests = obfsRequests
        decoder = ShadowsocksStreamDecoder(method: method, masterKey: master)
        encoder = ShadowsocksStreamEncoder(
            method: method, masterKey: master, salt: ShadowsocksConnector.randomSalt(method.saltLength))
        if !obfs { obfsHeader = nil }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var input = unwrapInboundIn(data)
        var reply = context.channel.allocator.buffer(capacity: 0)
        if var header = obfsHeader {
            header.writeBuffer(&input)
            guard let end = HTTPConnectHandshakeHandler.headerEnd(in: header.readableBytesView) else {
                obfsHeader = header
                return
            }
            obfsRequests.withLockedValue {
                $0.append(header.getString(at: header.readerIndex, length: end - header.readerIndex) ?? "")
            }
            header.moveReaderIndex(to: end)
            input = header
            obfsHeader = nil
            reply.writeString("HTTP/1.1 101 Switching Protocols\r\nServer: nginx\r\nUpgrade: websocket\r\n\r\n")
        }
        do {
            try decoder.decode(&input, into: &plain)
        } catch {
            context.close(promise: nil)
            return
        }
        if !parsedAddress {
            guard case .parsed(let destination, let length) = SOCKSAddress.parse(plain) else { return }
            destinations.withLockedValue { $0.append(destination) }
            plain.moveReaderIndex(forwardBy: length)
            parsedAddress = true
        }
        if plain.readableBytes > 0 {
            if corruptResponses {
                reply.writeBytes(ShadowsocksConnector.randomSalt(method.saltLength + 40))
            } else {
                try? encoder.encode(plain, into: &reply)
            }
            plain.clear()
        }
        if reply.readableBytes > 0 {
            context.writeAndFlush(wrapOutboundOut(reply), promise: nil)
        }
    }
}

/// 测试用 UDP 服务端：解包后把数据原样发回，来源为客户端发往的目标。
private final class TestShadowsocksUDPServer: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    let codec: ShadowsocksUDPCodec

    init(codec: ShadowsocksUDPCodec) {
        self.codec = codec
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard let (destination, payload) = codec.open(envelope.data, allocator: context.channel.allocator),
            let reply = try? codec.seal(
                payload, destination: destination, salt: ShadowsocksConnector.randomSalt(codec.method.saltLength),
                allocator: context.channel.allocator)
        else { return }
        context.writeAndFlush(
            wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: reply)), promise: nil)
    }
}

private final class Received: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let state = NIOLockedValueBox<(bytes: [UInt8], errors: [AetherErrorCode], closed: Bool)>(([], [], false))
    var bytes: [UInt8] { state.withLockedValue { $0.bytes } }
    var errors: [AetherErrorCode] { state.withLockedValue { $0.errors } }
    var closed: Bool { state.withLockedValue { $0.closed } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        state.withLockedValue { $0.bytes.append(contentsOf: buffer.readableBytesView) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if let error = error as? NetworkError {
            state.withLockedValue { $0.errors.append(error.code) }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        state.withLockedValue { $0.closed = true }
        context.fireChannelInactive()
    }
}

@Suite("Shadowsocks connector")
struct ShadowsocksConnectorTests {
    private func dialContext(_ loop: any EventLoop) -> DialContext {
        DialContext(
            flowID: FlowID(rawValue: 1), eventLoop: loop, deadline: .now() + .seconds(15),
            serverResolver: StaticResolver(table: ["ss.example.com": [IPAddress("127.0.0.1")!]]),
            logger: Logger(label: "test"))
    }

    private func attach(_ channel: any Channel) async throws -> Received {
        let received = Received()
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(received)
            try channel.syncOptions?.setOption(.autoRead, value: true)
            channel.read()
        }.get()
        return received
    }

    @Test(
        "The target address goes out on connect and data flows both ways, with and without simple-obfs http",
        arguments: [false, true])
    func tcp(obfs: Bool) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let method = ShadowsocksAEADMethod.chacha20IETFPoly1305
        let master = ShadowsocksKDF.bytesToKey(password: Array("secret".utf8), length: method.keyLength)
        let destinations = NIOLockedValueBox<[Destination]>([])
        let obfsRequests = NIOLockedValueBox<[String]>([])
        let server = try await LoopbackTCPServer.start(group: group) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    TestShadowsocksServer(
                        method: method, master: master, obfs: obfs, corruptResponses: false,
                        destinations: destinations, obfsRequests: obfsRequests))
            }
        }
        let connector = ShadowsocksConnector(
            name: "SS", server: ProxyServer(host: "ss.example.com", port: UInt16(server.port)), method: method,
            password: "secret", obfs: obfs ? SimpleObfsHTTPOptions(host: "cdn.example.org", uri: "obfs") : nil,
            udpEnabled: false)
        let channel = try await connector.connect(to: testDestination, context: dialContext(group.next())).get()
        #expect(await Poll.until { destinations.withLockedValue { $0 } == [testDestination] })
        let received = try await attach(channel)
        let payload = (0..<100_000).map { UInt8($0 % 239) }
        try await channel.writeAndFlush(ByteBuffer(bytes: payload))
        #expect(await Poll.until { received.bytes.count >= payload.count })
        #expect(received.bytes == payload)
        if obfs {
            let request = try #require(obfsRequests.withLockedValue { $0.first })
            #expect(request.hasPrefix("GET /obfs HTTP/1.1\r\n"))
            #expect(request.contains("\r\nHost: cdn.example.org:\(server.port)\r\n"))
            #expect(request.contains("\r\nUpgrade: websocket\r\n"))
        }
        try await channel.close()
        try await server.close()
        try await group.shutdownGracefully()
    }

    @Test("A response that fails authentication closes the connection with NET-032")
    func corruptResponse() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let method = ShadowsocksAEADMethod.aes256GCM
        let master = ShadowsocksKDF.bytesToKey(password: Array("secret".utf8), length: method.keyLength)
        let server = try await LoopbackTCPServer.start(group: group) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    TestShadowsocksServer(
                        method: method, master: master, obfs: false, corruptResponses: true,
                        destinations: NIOLockedValueBox([]), obfsRequests: NIOLockedValueBox([])))
            }
        }
        let connector = ShadowsocksConnector(
            name: "SS", server: ProxyServer(host: "127.0.0.1", port: UInt16(server.port)), method: method,
            password: "secret", udpEnabled: false)
        let channel = try await connector.connect(to: testDestination, context: dialContext(group.next())).get()
        let received = try await attach(channel)
        try await channel.writeAndFlush(ByteBuffer(string: "ping"))
        #expect(await Poll.until { received.closed })
        #expect(received.errors == [.netProtocolError])
        #expect(received.bytes.isEmpty)
        try await server.close()
        try await group.shutdownGracefully()
    }

    @Test("UDP relays through the server and reports the original target as the source; disabled UDP is NET-021")
    func udp() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let method = ShadowsocksAEADMethod.aes128GCM
        let master = ShadowsocksKDF.bytesToKey(password: Array("secret".utf8), length: method.keyLength)
        let codec = ShadowsocksUDPCodec(method: method, masterKey: master)
        let server = try await DatagramBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(TestShadowsocksUDPServer(codec: codec))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let port = UInt16(server.localAddress?.port ?? 0)
        let loop = group.next()

        let disabled = ShadowsocksConnector(
            name: "SS", server: ProxyServer(host: "ss.example.com", port: port), method: method, password: "secret",
            udpEnabled: false)
        await #expect(throws: NetworkError.self) { _ = try await disabled.openUDP(context: dialContext(loop)).get() }

        let connector = ShadowsocksConnector(
            name: "SS", server: ProxyServer(host: "ss.example.com", port: port), method: method, password: "secret",
            udpEnabled: true)
        let association = try await connector.openUDP(context: dialContext(loop)).get()
        let replies = NIOLockedValueBox<[(String, Destination)]>([])
        let target = Destination.ip(IPAddress("192.0.2.53")!, port: 53)
        try await loop.submit {
            association.onDatagram = { payload, source in
                replies.withLockedValue { $0.append((String(buffer: payload), source)) }
            }
            association.send(ByteBuffer(string: "query"), to: target)
            association.send(ByteBuffer(string: "named"), to: testDestination)
        }.get()
        #expect(await Poll.until { replies.withLockedValue { $0.count } == 2 })
        let got = replies.withLockedValue { $0 }
        #expect(got.contains { $0.0 == "query" && $0.1 == target })
        #expect(got.contains { $0.0 == "named" && $0.1 == testDestination })
        try await loop.submit { association.close() }.get()
        try await association.closeFuture.get()
        try await server.close()
        try await group.shutdownGracefully()
    }
}
