import AetherFoundation
import AetherOutbound
import AetherTestSupport
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing

@testable import AetherEngine

/// 固定表解析器。
struct FixedResolver: ServerAddressResolver {
    var table: [String: [IPAddress]] = [:]

    func resolve(_ host: String, family: AddressFamily, on eventLoop: any EventLoop) -> EventLoopFuture<[IPAddress]> {
        eventLoop.makeSucceededFuture((table[host] ?? []).filter { family == .v4 ? $0.isIPv4 : !$0.isIPv4 })
    }
}

private func dialContext(_ loop: any EventLoop) -> DialContext {
    DialContext(
        flowID: FlowID(rawValue: 1), eventLoop: loop, deadline: .now() + .seconds(15),
        serverResolver: FixedResolver(table: ["socks.example": [IPAddress("127.0.0.1")!]]),
        logger: Logger(label: "test"))
}

@Suite("SOCKS5 connector against the internal SOCKS5 inbound")
struct SOCKS5ConnectorTests {
    @Test("CONNECT with credentials, authentication failure, and UDP relay")
    func socks5() async throws {
        let threads = EngineThreads()
        let echo = try await LoopbackTCPServer.start(group: threads.group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
        }
        let acceptor = DirectTestAcceptor()
        let credentials = SOCKS5Credentials(username: "aether", password: "secret")
        let inbound = try await SOCKS5Inbound.start(on: threads.eventLoop, credentials: credentials, acceptor: acceptor)
            .get()
        let server = ProxyServer(host: "socks.example", port: UInt16(inbound.port))
        let connector = SOCKS5Connector(
            name: "S5", server: server, username: "aether", password: "secret", udpEnabled: true)
        #expect(connector.capabilities.contains(.udp))

        let channel = try await connector.connect(
            to: .domain(Hostname("localhost")!, port: UInt16(echo.port)), context: dialContext(threads.eventLoop)
        ).get()
        let collector = CollectingHandler()
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(collector)
            try channel.syncOptions?.setOption(.autoRead, value: true)
            channel.read()
        }.get()
        try await channel.writeAndFlush(ByteBuffer(string: "through socks"))
        #expect(await Poll.until { String(decoding: collector.bytes, as: UTF8.self) == "through socks" })
        // 有域名时用域名地址类型交给服务器。
        #expect(acceptor.requests.withLockedValue { $0.first?.destination.hostname?.value } == "localhost")
        try await channel.close()

        let wrong = SOCKS5Connector(name: "S5", server: server, username: "aether", password: "nope", udpEnabled: false)
        #expect(!wrong.capabilities.contains(.udp))
        do {
            _ = try await wrong.connect(
                to: .ip(IPAddress("127.0.0.1")!, port: 80), context: dialContext(threads.eventLoop)
            ).get()
            Issue.record("expected authentication failure")
        } catch let error as NetworkError {
            #expect(error.code == .netProxyAuthFailed)
        }
        do {
            _ = try await wrong.openUDP(context: dialContext(threads.eventLoop)).get()
            Issue.record("expected NET-021")
        } catch let error as NetworkError {
            #expect(error.code == .netPolicyNoUDP)
        }

        // UDP：内部入站的测试接收方原样回显，来源即目标。
        let association = try await connector.openUDP(context: dialContext(threads.eventLoop)).get()
        let received = NIOLockedValueBox<[(String, Destination)]>([])
        let target = Destination.ip(IPAddress("192.0.2.53")!, port: 53)
        try await threads.eventLoop.submit {
            association.onDatagram = { payload, source in
                received.withLockedValue { $0.append((String(buffer: payload), source)) }
            }
            association.send(ByteBuffer(string: "query"), to: target)
        }.get()
        #expect(await Poll.until { received.withLockedValue { $0.count } == 1 })
        #expect(received.withLockedValue { $0.first?.0 } == "query")
        #expect(received.withLockedValue { $0.first?.1 } == target)
        // 服务器端关联结束（控制连接关闭）后客户端关联随之关闭。
        let serverSide = try #require(acceptor.associations.withLockedValue { $0.first })
        try await threads.eventLoop.submit { serverSide.close() }.get()
        try await association.closeFuture.get()

        try await inbound.close().get()
        try await echo.close()
        try await threads.shutdown()
    }
}

@Suite("Reject policies")
struct RejectControllerTests {
    @Test("More than 10 REJECTs per second upgrade the host to DROP for 30 s; NO-DROP never upgrades")
    func stormProtection() {
        let loop = EmbeddedEventLoop()
        let controller = RejectController(eventLoop: loop)
        for _ in 0..<10 {
            #expect(controller.effectiveKind(.reject, host: "ads.example.com") == .reject)
        }
        #expect(controller.effectiveKind(.reject, host: "ads.example.com") == .reject)
        #expect(controller.effectiveKind(.reject, host: "ads.example.com") == .drop)
        #expect(controller.effectiveKind(.noDrop, host: "ads.example.com") == .noDrop)
        #expect(controller.effectiveKind(.tinyGIF, host: "ads.example.com") == .tinyGIF)
        #expect(controller.effectiveKind(.reject, host: "other.example.com") == .reject)
        loop.advanceTime(by: .seconds(29))
        #expect(controller.effectiveKind(.reject, host: "ads.example.com") == .drop)
        loop.advanceTime(by: .seconds(2))
        #expect(controller.effectiveKind(.reject, host: "ads.example.com") == .reject)
    }

    @Test("Slow rejects never trigger the upgrade")
    func slowRejects() {
        let loop = EmbeddedEventLoop()
        let controller = RejectController(eventLoop: loop)
        for _ in 0..<50 {
            #expect(controller.effectiveKind(.reject, host: "slow.example.com") == .reject)
            loop.advanceTime(by: .milliseconds(200))
        }
    }

    @Test("DROP holds the connection until the peer closes or 60 s pass, capped at 256")
    func dropHolding() throws {
        let loop = EmbeddedEventLoop()
        let controller = RejectController(eventLoop: loop)
        let held = EmbeddedChannel(loop: loop)
        try held.connect(to: SocketAddress(ipAddress: "192.0.2.1", port: 1)).wait()
        controller.rejectTCP(.drop, channel: held)
        #expect(controller.heldConnections == 1)
        try held.writeInbound(ByteBuffer(string: "ignored"))
        #expect(try held.readOutbound(as: ByteBuffer.self) == nil)
        loop.advanceTime(by: .seconds(59))
        #expect(held.isActive)
        loop.advanceTime(by: .seconds(1))
        #expect(!held.isActive)
        #expect(controller.heldConnections == 0)

        let rejected = EmbeddedChannel(loop: loop)
        try rejected.connect(to: SocketAddress(ipAddress: "192.0.2.1", port: 2)).wait()
        controller.rejectTCP(.reject, channel: rejected)
        #expect(!rejected.isActive)

        var channels: [EmbeddedChannel] = []
        for index in 0..<RejectController.dropLimit {
            let channel = EmbeddedChannel(loop: loop)
            try channel.connect(to: SocketAddress(ipAddress: "192.0.2.1", port: 10 + index)).wait()
            controller.rejectTCP(.drop, channel: channel)
            channels.append(channel)
        }
        #expect(controller.heldConnections == RejectController.dropLimit)
        #expect(controller.effectiveKind(.drop, host: nil) == .reject)
        _ = try channels[0].close().wait()
        loop.run()
        #expect(controller.effectiveKind(.drop, host: nil) == .drop)
        #expect(controller.httpResponse(for: .reject, errorPage: true) == .forbidden(errorPage: true))
        #expect(controller.httpResponse(for: .tinyGIF, errorPage: false) == .tinyGIF)
        #expect(controller.httpResponse(for: .drop, errorPage: false) == .drop(.seconds(60)))
    }
}
