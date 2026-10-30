import AetherFoundation
import AetherTestSupport
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import AetherDNS

/// 按标准规则构造应答：A → 192.0.2.80，其余 NOERROR 空答案；`padding` 条 TXT 记录用于制造大报文。
private func standardResponse(to query: DNSMessage, padding: Int) -> DNSMessage {
    guard let question = query.questions.first else { return DNSMessage.response(to: query, code: .formatError) }
    var answers: [DNSResourceRecord] = []
    if question.type == .a {
        answers.append(DNSResourceRecord(name: question.name, type: .a, ttl: 60, data: .a(IPv4Address(192, 0, 2, 80))))
    }
    for _ in 0..<padding {
        answers.append(
            DNSResourceRecord(
                name: question.name, type: .txt, ttl: 60, data: .opaque([40] + Array(repeating: 0x42, count: 40))))
    }
    return DNSMessage.response(to: query, answers: answers)
}

/// UDP 应答：`truncate` 时只回 TC 位的空应答（迫使客户端改用 TCP）。
private final class UDPResponder: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    let truncate: Bool
    let counter: NIOLockedValueBox<Int>

    init(truncate: Bool, counter: NIOLockedValueBox<Int>) {
        self.truncate = truncate
        self.counter = counter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard let query = try? DNSMessage.decode(Array(envelope.data.readableBytesView)) else { return }
        counter.withLockedValue { $0 += 1 }
        var response = standardResponse(to: query, padding: truncate ? 0 : 0)
        if truncate {
            response.answers = []
            response.header.isTruncated = true
        }
        let out = AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: ByteBuffer(bytes: response.encode()))
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }
}

/// TCP 应答：长度前缀分帧，带 30 条填充记录（远超 512 字节）。
private final class TCPResponder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let counter: NIOLockedValueBox<Int>
    private var buffer = ByteBuffer()

    init(counter: NIOLockedValueBox<Int>) {
        self.counter = counter
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let frame = DNSStreamFraming.nextFrame(from: &buffer) {
            guard let query = try? DNSMessage.decode(frame) else { continue }
            counter.withLockedValue { $0 += 1 }
            let response = standardResponse(to: query, padding: 30).encode()
            context.writeAndFlush(
                wrapOutboundOut(DNSStreamFraming.frame(response, allocator: context.channel.allocator)), promise: nil)
        }
    }
}

/// 回环上的测试 DNS 服务（UDP 与 TCP 监听同一端口）。
private struct TestDNSServer {
    let udp: any Channel
    let tcp: any Channel
    let udpQueries: NIOLockedValueBox<Int>
    let tcpQueries: NIOLockedValueBox<Int>

    var address: SocketAddress {
        get throws { try SocketAddress(ipAddress: "127.0.0.1", port: udp.localAddress?.port ?? 0) }
    }

    static func start(group: any EventLoopGroup, truncateUDP: Bool) async throws -> TestDNSServer {
        let udpQueries = NIOLockedValueBox(0)
        let tcpQueries = NIOLockedValueBox(0)
        let udp = try await DatagramBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        UDPResponder(truncate: truncateUDP, counter: udpQueries))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        let tcp = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(TCPResponder(counter: tcpQueries))
                }
            }
            .bind(host: "127.0.0.1", port: udp.localAddress?.port ?? 0).get()
        return TestDNSServer(udp: udp, tcp: tcp, udpQueries: udpQueries, tcpQueries: tcpQueries)
    }

    func close() async throws {
        try await udp.close()
        try await tcp.close()
    }
}

private func query(_ domain: String, _ type: DNSRecordType, id: UInt16) -> [UInt8] {
    var message = DNSMessage(header: DNSHeader(id: id))
    message.questions = [DNSQuestion(name: DNSName(domain)!, type: type)]
    return message.encode()
}

@Suite("DNS over sockets (loopback)")
struct DNSSocketTests {
    @Test("UDP upstream answers a query")
    func udpQuery() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await TestDNSServer.start(group: group, truncateUDP: false)
        let upstream = UDPDNSUpstream(address: try server.address)
        let response = try await upstream.send(query("www.example.com", .a, id: 0x1111), on: group.next()).get()
        let message = try DNSMessage.decode(response)
        #expect(message.header.id == 0x1111)
        #expect(message.answers.first?.address == IPAddress("192.0.2.80"))
        #expect(server.udpQueries.withLockedValue { $0 } == 1)
        #expect(server.tcpQueries.withLockedValue { $0 } == 0)
        try await server.close()
        try await group.shutdownGracefully()
    }

    @Test("A truncated UDP answer is retried over TCP")
    func truncatedFallsBackToTCP() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let server = try await TestDNSServer.start(group: group, truncateUDP: true)
        let upstream = UDPDNSUpstream(address: try server.address)
        let response = try await upstream.send(query("big.example.com", .a, id: 0x2222), on: group.next()).get()
        let message = try DNSMessage.decode(response)
        #expect(!message.header.isTruncated)
        #expect(message.answers.count == 31)
        #expect(response.count > 512)
        #expect(server.tcpQueries.withLockedValue { $0 } == 1)
        try await server.close()
        try await group.shutdownGracefully()
    }

    @Test("DNS over TCP server handler answers framed queries")
    func streamServer() async throws {
        let threads = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = threads.next()
        let service = try await loop.submit {
            var configuration = DNSConfiguration()
            configuration.servers = []
            return DNSService(configuration: configuration, environment: .init(eventLoop: loop))
        }.get()
        let server = try await LoopbackTCPServer.start(group: loop) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(DNSStreamServerHandler(service: service))
            }
        }
        let collector = CollectingHandler()
        let client = try await ClientBootstrap(group: loop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
            }
            .connect(host: "127.0.0.1", port: server.port).get()
        var payload = ByteBuffer()
        for (index, domain) in ["a.example.com", "b.example.com"].enumerated() {
            let bytes = query(domain, .a, id: UInt16(index + 1))
            payload.writeInteger(UInt16(bytes.count))
            payload.writeBytes(bytes)
        }
        try await client.writeAndFlush(payload)
        let complete = await Poll.until {
            var buffer = ByteBuffer(bytes: collector.bytes)
            return DNSStreamFraming.nextFrame(from: &buffer) != nil && DNSStreamFraming.nextFrame(from: &buffer) != nil
        }
        #expect(complete)
        var buffer = ByteBuffer(bytes: collector.bytes)
        let ids = try [DNSStreamFraming.nextFrame(from: &buffer), DNSStreamFraming.nextFrame(from: &buffer)]
            .compactMap { $0 }.map { try DNSMessage.decode($0) }.map(\.header.id)
        #expect(Set(ids) == [1, 2])
        try await client.close()
        try await server.close()
        try await threads.shutdownGracefully()
    }

    @Test("System upstream excludes tunnel addresses and falls back to getaddrinfo")
    func systemFallback() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let pool = NIOThreadPool(numberOfThreads: 1)
        pool.start()
        let upstream = SystemDNSUpstream(
            provider: { [IPAddress("198.18.0.2")!] }, excluded: [CIDR("198.18.0.0/15")!], blockingPool: pool)
        #expect(upstream.currentServers.isEmpty)
        let response = try await upstream.send(query("localhost", .a, id: 7), on: group.next()).get()
        let message = try DNSMessage.decode(response)
        #expect(message.header.id == 7)
        #expect(message.answers.contains { $0.address == IPAddress("127.0.0.1") })
        let txt = try DNSMessage.decode(
            try await upstream.send(query("localhost", .txt, id: 8), on: group.next()).get())
        #expect(txt.header.responseCode == .serverFailure)
        try await pool.shutdownGracefully()
        try await group.shutdownGracefully()
    }
}
