import AetherFoundation
import AetherOutbound
import AetherTestSupport
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing

@testable import AetherEngine

/// 回显服务的 Handler。
final class EchoHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}

/// 测试用接收方：TCP 直接连到目标（`localhost` 视为 127.0.0.1）并胶合；UDP 原样回显。
final class DirectTestAcceptor: InboundAcceptor, @unchecked Sendable {
    let requests = NIOLockedValueBox<[InboundTCPRequest]>([])
    let associations = NIOLockedValueBox<[SOCKS5UDPAssociation]>([])

    func acceptTCP(_ request: InboundTCPRequest, channel: any Channel) {
        requests.withLockedValue { $0.append(request) }
        let host = request.destination.hostText == "localhost" ? "127.0.0.1" : request.destination.hostText
        ChannelTuning.configure(ClientBootstrap(group: channel.eventLoop))
            .connect(host: host, port: Int(request.destination.port))
            .whenComplete { result in
                switch result {
                case .success(let outbound):
                    _ = try? FlowRelay.glue(
                        inbound: channel, outbound: outbound, counters: FlowCounters(),
                        initialUpload: request.initialData)
                case .failure:
                    channel.close(promise: nil)
                }
            }
    }

    func acceptUDP(_ association: SOCKS5UDPAssociation) {
        associations.withLockedValue { $0.append(association) }
        association.onDatagram = { [weak association] destination, payload in
            association?.send(payload, from: destination)
        }
    }
}

/// UDP 测试客户端：收集收到的数据报。
private final class DatagramCollector: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    let received = NIOLockedValueBox<[[UInt8]]>([])

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        received.withLockedValue { $0.append(Array(envelope.data.readableBytesView)) }
    }
}

private let credentials = SOCKS5Credentials(username: "aether", password: "secret")

private func greetingAndAuth(user: String = "aether", password: String = "secret") -> [UInt8] {
    [5, 1, 2] + [1, UInt8(user.utf8.count)] + Array(user.utf8) + [UInt8(password.utf8.count)] + Array(password.utf8)
}

private func connectRequest(_ destination: Destination, command: UInt8 = 1) -> [UInt8] {
    var buffer = ByteBuffer(bytes: [5, command, 0])
    SOCKSAddress.write(destination, to: &buffer)
    return Array(buffer.readableBytesView)
}

private struct SOCKSFixture {
    let threads: EngineThreads
    let echo: LoopbackTCPServer
    let acceptor: DirectTestAcceptor
    let inbound: SOCKS5Inbound

    static func start() async throws -> SOCKSFixture {
        let threads = EngineThreads()
        let echo = try await LoopbackTCPServer.start(group: threads.group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
        }
        let acceptor = DirectTestAcceptor()
        let inbound = try await SOCKS5Inbound.start(
            on: threads.eventLoop, credentials: credentials, acceptor: acceptor
        ).get()
        return SOCKSFixture(threads: threads, echo: echo, acceptor: acceptor, inbound: inbound)
    }

    func client() async throws -> (channel: any Channel, collector: CollectingHandler) {
        let collector = CollectingHandler()
        let channel = try await ClientBootstrap(group: threads.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
            }
            .connect(host: "127.0.0.1", port: inbound.port).get()
        return (channel, collector)
    }

    func stop() async throws {
        try await inbound.close().get()
        try await echo.close()
        try await threads.shutdown()
    }
}

@Suite("Internal SOCKS5 inbound")
struct SOCKS5InboundTests {
    @Test("Pipelined handshake, CONNECT to IPv4 and early data reach the server")
    func connectIPv4() async throws {
        let fixture = try await SOCKSFixture.start()
        let (client, collector) = try await fixture.client()
        let destination = Destination.ip(IPAddress("127.0.0.1")!, port: UInt16(fixture.echo.port))
        try await client.writeAndFlush(
            ByteBuffer(bytes: greetingAndAuth() + connectRequest(destination) + Array("early".utf8)))
        let expectedHandshake: [UInt8] = [5, 2, 1, 0, 5, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        #expect(await Poll.until { collector.bytes.count == expectedHandshake.count + 5 })
        #expect(Array(collector.bytes.prefix(expectedHandshake.count)) == expectedHandshake)
        #expect(String(decoding: collector.bytes.dropFirst(expectedHandshake.count), as: UTF8.self) == "early")

        try await client.writeAndFlush(ByteBuffer(string: "more"))
        #expect(await Poll.until { collector.bytes.count == expectedHandshake.count + 9 })

        let request = try #require(fixture.acceptor.requests.withLockedValue { $0.first })
        #expect(request.destination == destination)
        #expect(request.inbound == .tun)
        #expect(request.replied)
        #expect(request.initialData.map { String(buffer: $0) } == "early")
        #expect(request.inboundPort == UInt16(fixture.inbound.port))

        try await client.close()
        try await fixture.stop()
    }

    @Test("CONNECT with a domain name keeps the name for routing")
    func connectDomain() async throws {
        let fixture = try await SOCKSFixture.start()
        let (client, collector) = try await fixture.client()
        let destination = Destination.domain(Hostname("LocalHost")!, port: UInt16(fixture.echo.port))
        try await client.writeAndFlush(ByteBuffer(bytes: greetingAndAuth() + connectRequest(destination)))
        #expect(await Poll.until { collector.bytes.count == 14 })
        try await client.writeAndFlush(ByteBuffer(string: "ping"))
        #expect(await Poll.until { collector.bytes.count == 18 })
        let request = try #require(fixture.acceptor.requests.withLockedValue { $0.first })
        #expect(request.destination.hostname?.value == "localhost")
        #expect(request.initialData == nil)
        try await client.close()
        try await fixture.stop()
    }

    @Test("Wrong credentials and missing user/password method are refused")
    func authenticationFailures() async throws {
        let fixture = try await SOCKSFixture.start()
        let (wrong, wrongCollector) = try await fixture.client()
        try await wrong.writeAndFlush(ByteBuffer(bytes: greetingAndAuth(password: "nope")))
        #expect(await Poll.until { wrongCollector.isClosed })
        #expect(wrongCollector.bytes == [5, 2, 1, 1])

        let (noAuth, noAuthCollector) = try await fixture.client()
        try await noAuth.writeAndFlush(ByteBuffer(bytes: [5, 1, 0]))
        #expect(await Poll.until { noAuthCollector.isClosed })
        #expect(noAuthCollector.bytes == [5, 0xFF])
        #expect(fixture.acceptor.requests.withLockedValue { $0.isEmpty })
        try await fixture.stop()
    }

    @Test("BIND and unknown address types get the right reply codes")
    func unsupported() async throws {
        let fixture = try await SOCKSFixture.start()
        let (bind, bindCollector) = try await fixture.client()
        let destination = Destination.ip(IPAddress("192.0.2.1")!, port: 80)
        try await bind.writeAndFlush(ByteBuffer(bytes: greetingAndAuth() + connectRequest(destination, command: 2)))
        #expect(await Poll.until { bindCollector.isClosed })
        #expect(Array(bindCollector.bytes.dropFirst(4).prefix(2)) == [5, 0x07])

        let (badType, badTypeCollector) = try await fixture.client()
        try await badType.writeAndFlush(ByteBuffer(bytes: greetingAndAuth() + [5, 1, 0, 0x05, 1, 2, 3, 4, 0, 80]))
        #expect(await Poll.until { badTypeCollector.isClosed })
        #expect(Array(badTypeCollector.bytes.dropFirst(4).prefix(2)) == [5, 0x08])
        try await fixture.stop()
    }

    @Test("UDP ASSOCIATE relays datagrams, drops fragments and ends with the control connection")
    func udpAssociate() async throws {
        let fixture = try await SOCKSFixture.start()
        let (control, collector) = try await fixture.client()
        try await control.writeAndFlush(
            ByteBuffer(bytes: greetingAndAuth() + connectRequest(.ip(IPAddress("0.0.0.0")!, port: 0), command: 3)))
        #expect(await Poll.until { collector.bytes.count == 14 })
        let reply = collector.bytes
        #expect(Array(reply[4..<12]) == [5, 0, 0, 1, 127, 0, 0, 1])
        let relayPort = Int(reply[12]) << 8 | Int(reply[13])
        #expect(relayPort > 0)

        let received = DatagramCollector()
        let udp = try await DatagramBootstrap(group: fixture.threads.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(received) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let relay = try SocketAddress(ipAddress: "127.0.0.1", port: relayPort)
        let header: [UInt8] = [0, 0, 0, 1, 192, 0, 2, 53, 0, 53]
        try await udp.writeAndFlush(
            AddressedEnvelope(remoteAddress: relay, data: ByteBuffer(bytes: header + Array("ping".utf8))))
        #expect(await Poll.until { received.received.withLockedValue { $0.count } == 1 })
        #expect(received.received.withLockedValue { $0.first } == header + Array("ping".utf8))

        // FRAG ≠ 0 的数据报被丢弃。
        var fragmented = header
        fragmented[2] = 1
        try await udp.writeAndFlush(AddressedEnvelope(remoteAddress: relay, data: ByteBuffer(bytes: fragmented + [1])))
        let association = try #require(fixture.acceptor.associations.withLockedValue { $0.first })
        #expect(
            await Poll.until { (try? await association.eventLoop.submit { association.droppedDatagrams }.get()) == 1 })
        #expect(received.received.withLockedValue { $0.count } == 1)

        // 关闭控制连接即结束关联。
        try await control.close()
        try await association.datagram.closeFuture.get()

        try await udp.close()
        try await fixture.stop()
    }
}

@Suite("SOCKS5 handshake limits")
struct SOCKS5HandshakeLimitTests {
    @Test("Unfinished handshakes are closed after the timeout")
    func timeout() throws {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        try channel.pipeline.syncOperations.addHandler(
            SOCKS5ServerHandler(
                credentials: credentials, acceptor: DirectTestAcceptor(), handshakeTimeout: .seconds(10)))
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        try channel.writeInbound(ByteBuffer(bytes: [5, 1]))
        loop.advanceTime(by: .seconds(9))
        #expect(channel.isActive)
        loop.advanceTime(by: .seconds(1))
        #expect(!channel.isActive)
    }

    @Test("More than 1 KiB of unfinished handshake closes the connection")
    func oversized() throws {
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            SOCKS5ServerHandler(credentials: credentials, acceptor: DirectTestAcceptor()))
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        // 宣称 255 个方法但数据一直不完整：缓冲超过 1 KiB 时关闭。
        try channel.writeInbound(ByteBuffer(bytes: [5, 255] + Array(repeating: 0, count: 200)))
        #expect(channel.isActive)
        _ = try? channel.writeInbound(ByteBuffer(bytes: Array(repeating: 0, count: 1000)))
        #expect(!channel.isActive)
    }

    @Test("Random credentials are 32 hex characters")
    func randomCredentials() {
        let first = SOCKS5Credentials.random()
        let second = SOCKS5Credentials.random()
        #expect(first.username.count == 32 && first.password.count == 32)
        #expect(first != second)
    }
}
