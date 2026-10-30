import AetherDNS
import AetherFoundation
import AetherIPC
import AetherOutbound
import AetherProfile
import AetherTestSupport
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing

@testable import AetherEngine

// MARK: - NAT 表（确定性）

private final class FakeClient: InboundUDPClient {
    var onDatagram: ((Destination, ByteBuffer) -> Void)?
    var onClose: (() -> Void)?
    var sent: [(String, Destination)] = []
    var closed = false

    func send(_ payload: ByteBuffer, from source: Destination) {
        sent.append((String(buffer: payload), source))
    }

    func close() {
        guard !closed else { return }
        closed = true
        let callback = onClose
        onClose = nil
        callback?()
    }

    func deliver(_ text: String, to destination: Destination) {
        onDatagram?(destination, ByteBuffer(string: text))
    }
}

private final class FakeOutbound: OutboundUDPAssociation, @unchecked Sendable {
    var onDatagram: ((ByteBuffer, Destination) -> Void)?
    var sent: [(String, Destination)] = []
    private let promise: EventLoopPromise<Void>
    private(set) var closed = false

    init(loop: any EventLoop) {
        promise = loop.makePromise()
    }

    var closeFuture: EventLoopFuture<Void> { promise.futureResult }

    func send(_ payload: ByteBuffer, to destination: Destination) {
        sent.append((String(buffer: payload), destination))
    }

    func close() {
        guard !closed else { return }
        closed = true
        promise.succeed(())
    }

    func reply(_ text: String, from source: Destination) {
        onDatagram?(ByteBuffer(string: text), source)
    }
}

private let dnsTarget = Destination.ip(IPAddress("198.18.0.2")!, port: 53)
private let fakeA = Destination.ip(IPAddress("198.18.0.5")!, port: 443)
private let fakeB = Destination.ip(IPAddress("198.18.0.6")!, port: 443)
private let realC = Destination.ip(IPAddress("203.0.113.9")!, port: 3478)
private let domainA = Destination.domain(Hostname("a.example.com")!, port: 443)
private let domainB = Destination.domain(Hostname("b.example.com")!, port: 443)

private final class NATHarness {
    let loop = EmbeddedEventLoop()
    let client = FakeClient()
    let requests: RequestLog
    let session: UDPSession
    var routeCalls = 0
    var closedCallbacks = 0

    init(
        settings: UDPSession.Settings = UDPSession.Settings(),
        route: @escaping (NATHarness, Destination) -> EventLoopFuture<UDPRoute>
    ) {
        requests = RequestLog(eventLoop: loop)
        var nextID: UInt64 = 0
        var routeBox: ((Destination) -> EventLoopFuture<UDPRoute>)?
        let loop = self.loop
        session = UDPSession(
            client: client, eventLoop: loop, requests: requests, settings: settings,
            hooks: UDPSession.Hooks(
                isDNSTarget: { $0 == dnsTarget },
                answerDNS: { payload in
                    loop.makeSucceededFuture(ByteBuffer(string: "answer:\(String(buffer: payload))"))
                },
                route: { destination, _, _ in
                    routeBox?(destination) ?? loop.makeFailedFuture(ChannelError.ioOnClosedChannel)
                },
                allocateID: {
                    nextID += 1
                    return FlowID(rawValue: nextID)
                },
                onTraffic: nil))
        routeBox = { [unowned self] destination in
            self.routeCalls += 1
            return route(self, destination)
        }
        session.onClosed = { [unowned self] in self.closedCallbacks += 1 }
        session.start()
    }

    func forward(
        _ target: Destination, key: String = "proxy", outbound: FakeOutbound, opens: NIOLockedValueBox<Int>
    ) -> EventLoopFuture<UDPRoute> {
        loop.makeSucceededFuture(
            .forward(
                key: key, policy: "Proxy", target: target,
                open: { [loop] in
                    opens.withLockedValue { $0 += 1 }
                    return loop.makeSucceededFuture(outbound)
                }))
    }

    var records: [RequestRecord] { requests.recent + requests.activeRecords }
}

@Suite("UDP NAT table (06 §10)")
struct UDPSessionTests {
    @Test(
        "Each destination is routed once, one policy shares one outbound, replies come back from the address the client used"
    )
    func sharedOutboundAndReplyMapping() {
        let opens = NIOLockedValueBox(0)
        var outbound: FakeOutbound?
        let harness = NATHarness { harness, destination in
            let target = [fakeA: domainA, fakeB: domainB][destination] ?? destination
            return harness.forward(target, outbound: outbound!, opens: opens)
        }
        outbound = FakeOutbound(loop: harness.loop)
        let out = outbound!
        harness.client.deliver("a1", to: fakeA)
        harness.loop.advanceTime(by: .seconds(1))
        harness.client.deliver("b1", to: fakeB)
        harness.loop.advanceTime(by: .seconds(1))
        harness.client.deliver("c1", to: realC)
        harness.client.deliver("a2", to: fakeA)
        #expect(out.sent.map(\.0) == ["a1", "b1", "c1", "a2"])
        #expect(out.sent.map(\.1) == [domainA, domainB, realC, domainA])
        #expect(opens.withLockedValue { $0 } == 1)
        #expect(harness.routeCalls == 3)
        #expect(harness.session.flowCount == 3 && harness.session.outboundCount == 1)

        // 精确反查：域名目标回包以 Fake IP 为来源。
        out.reply("ra", from: domainA)
        #expect(harness.client.sent.last! == ("ra", fakeA))
        // 服务器以解析后的 IP 回包：归于同端口域名目标中最近活动的流（fakeA 刚收到回包，最近）。
        harness.loop.advanceTime(by: .seconds(1))
        harness.client.deliver("b2", to: fakeB)
        out.reply("rb", from: .ip(IPAddress("203.0.113.20")!, port: 443))
        #expect(harness.client.sent.last! == ("rb", fakeB))
        // 真实 IP 目标原样往返；未知来源按完全锥形 NAT 原样转发。
        out.reply("rc", from: realC)
        #expect(harness.client.sent.last! == ("rc", realC))
        let stranger = Destination.ip(IPAddress("198.51.100.7")!, port: 3478)
        out.reply("rs", from: stranger)
        #expect(harness.client.sent.last! == ("rs", stranger))

        let records = harness.records
        #expect(records.count == 3)
        #expect(records.allSatisfy { $0.transport == .udp && $0.state == .active })
        #expect(records.first { $0.destination == fakeA.description }?.remoteAddress == domainA.description)
        harness.session.close()
        #expect(out.closed && harness.client.closed && harness.closedCallbacks == 1)
        #expect(harness.records.allSatisfy { $0.state == .completed })
        #expect(harness.records.first { $0.destination == fakeA.description }?.bytesUp == 4)
        #expect(harness.records.first { $0.destination == fakeA.description }?.bytesDown == 2)
    }

    @Test("Datagrams wait in a 32-packet queue while routing; the oldest are dropped")
    func pendingQueue() {
        let opens = NIOLockedValueBox(0)
        var promise: EventLoopPromise<UDPRoute>?
        let harness = NATHarness { harness, _ in
            promise = harness.loop.makePromise()
            return promise!.futureResult
        }
        let out = FakeOutbound(loop: harness.loop)
        for index in 0..<40 {
            harness.client.deliver("d\(index)", to: fakeA)
        }
        #expect(harness.routeCalls == 1)
        promise!.completeWith(harness.forward(domainA, outbound: out, opens: opens))
        harness.loop.run()
        #expect(out.sent.map(\.0) == (8..<40).map { "d\($0)" })
        #expect(harness.session.droppedDatagrams == 8)
        harness.session.close()
    }

    @Test("A dropped destination stays dropped until the retry time, then is routed again")
    func dropAndRetry() {
        let harness = NATHarness { harness, _ in
            harness.loop.makeSucceededFuture(.drop(NetworkError(.netRejected, "Rejected by REJECT")))
        }
        harness.client.deliver("x", to: realC)
        #expect(harness.records.first?.errorCode == "NET-022")
        harness.client.deliver("y", to: realC)
        #expect(harness.routeCalls == 1)
        #expect(harness.session.droppedDatagrams == 2)
        harness.loop.advanceTime(by: .seconds(10))
        harness.client.deliver("z", to: realC)
        #expect(harness.routeCalls == 2)
        #expect(harness.records.count == 2)
        harness.session.close()
    }

    @Test("DNS datagrams are answered without routing; an association carrying only DNS closes after 10 s")
    func dnsOnly() {
        let harness = NATHarness { harness, _ in
            Issue.record("DNS must not be routed")
            return harness.loop.makeSucceededFuture(.drop(NetworkError(.netRejected, "")))
        }
        harness.client.deliver("q", to: dnsTarget)
        harness.loop.run()
        #expect(harness.client.sent.count == 1)
        #expect(harness.client.sent.first! == ("answer:q", dnsTarget))
        #expect(harness.records.isEmpty)
        harness.loop.advanceTime(by: .seconds(9))
        #expect(!harness.client.closed)
        harness.loop.advanceTime(by: .seconds(1))
        #expect(harness.client.closed && harness.closedCallbacks == 1)
    }

    @Test("Idle flows end after 60 s, an unused outbound closes, and the idle association closes")
    func idleRecycling() {
        let opens = NIOLockedValueBox(0)
        var outbound: FakeOutbound?
        let harness = NATHarness { harness, destination in
            harness.forward(destination == fakeA ? domainA : domainB, outbound: outbound!, opens: opens)
        }
        outbound = FakeOutbound(loop: harness.loop)
        harness.client.deliver("a", to: fakeA)
        harness.loop.advanceTime(by: .seconds(30))
        harness.client.deliver("b", to: fakeB)
        harness.loop.advanceTime(by: .seconds(31))
        // fakeA 已空闲 61 秒：结束；fakeB 仍在用出站关联。
        #expect(harness.session.flowCount == 1)
        #expect(harness.records.first { $0.destination == fakeA.description }?.state == .completed)
        #expect(!outbound!.closed)
        harness.loop.advanceTime(by: .seconds(30))
        #expect(harness.client.closed)
        #expect(outbound!.closed)
        #expect(harness.records.allSatisfy { $0.state == .completed })
    }

    @Test("When the outbound association closes its flows end; the next datagram is routed again and reopens it")
    func outboundClosure() {
        let opens = NIOLockedValueBox(0)
        var outbounds: [FakeOutbound] = []
        let harness = NATHarness { harness, _ in
            let out = FakeOutbound(loop: harness.loop)
            outbounds.append(out)
            return harness.forward(domainA, outbound: out, opens: opens)
        }
        harness.client.deliver("one", to: fakeA)
        outbounds[0].close()
        harness.loop.run()
        #expect(harness.session.flowCount == 0)
        #expect(harness.records.first?.state == .completed)
        harness.client.deliver("two", to: fakeA)
        #expect(opens.withLockedValue { $0 } == 2)
        #expect(outbounds[1].sent.map(\.0) == ["two"])
        harness.session.close()
    }

    @Test("Beyond the flow limit the least recently active flow ends")
    func flowLimit() {
        let opens = NIOLockedValueBox(0)
        var outbound: FakeOutbound?
        var settings = UDPSession.Settings()
        settings.flowLimit = 2
        let harness = NATHarness(settings: settings) { harness, destination in
            harness.forward(destination, outbound: outbound!, opens: opens)
        }
        outbound = FakeOutbound(loop: harness.loop)
        harness.client.deliver("a", to: fakeA)
        harness.loop.advanceTime(by: .seconds(1))
        harness.client.deliver("b", to: fakeB)
        harness.loop.advanceTime(by: .seconds(1))
        harness.client.deliver("c", to: realC)
        #expect(harness.session.flowCount == 2)
        #expect(harness.records.first { $0.destination == fakeA.description }?.state == .completed)
        #expect(!outbound!.closed)
        harness.session.close()
    }

    @Test("QUIC long headers are recognised")
    func quicHeader() {
        #expect(Sniffer.isQUICLongHeader(ByteBuffer(bytes: [0xC3, 0, 0, 0, 1, 8])))
        #expect(!Sniffer.isQUICLongHeader(ByteBuffer(bytes: [0xC3, 0, 0, 0, 0])))
        #expect(!Sniffer.isQUICLongHeader(ByteBuffer(bytes: [0x43, 0, 0, 0, 1])))
        #expect(!Sniffer.isQUICLongHeader(ByteBuffer(bytes: [0xC3])))
    }
}

// MARK: - 路由集成

/// 回环 UDP 回显源站。
private final class UDPEcho: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        context.writeAndFlush(
            wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: envelope.data)), promise: nil
        )
    }
}

/// 像 hev 一样经内部 SOCKS5 入站建立 UDP 关联，收集回包。
private final class HevUDPClient: Sendable {
    let association: any OutboundUDPAssociation
    let received = NIOLockedValueBox<[(String, Destination)]>([])
    let loop: any EventLoop

    private init(association: any OutboundUDPAssociation, loop: any EventLoop) {
        self.association = association
        self.loop = loop
    }

    static func open(_ harness: RouterHarness) async throws -> HevUDPClient {
        let connector = SOCKS5Connector(
            name: "hev", server: ProxyServer(host: "127.0.0.1", port: UInt16(harness.socks.port)), username: "hev",
            password: "secret", udpEnabled: true)
        let loop = harness.threads.eventLoop
        let context = DialContext(
            flowID: FlowID(rawValue: 0), eventLoop: loop, deadline: .now() + .seconds(15),
            serverResolver: FixedResolver(), logger: Logger(label: "test"))
        let association = try await connector.openUDP(context: context).get()
        let client = HevUDPClient(association: association, loop: loop)
        try await loop.submit {
            association.onDatagram = { payload, source in
                client.received.withLockedValue { $0.append((String(buffer: payload), source)) }
            }
        }.get()
        return client
    }

    func send(_ payload: ByteBuffer, to destination: Destination) async throws {
        let association = self.association
        try await loop.submit { association.send(payload, to: destination) }.get()
    }

    /// 发送并等待第 `count` 个回包。
    func exchange(_ text: String, to destination: Destination, expecting count: Int) async throws -> (
        String, Destination
    )? {
        try await send(ByteBuffer(string: text), to: destination)
        _ = await Poll.until { self.received.withLockedValue { $0.count } >= count }
        return received.withLockedValue { $0.count >= count ? $0[count - 1] : nil }
    }

    func close() async throws {
        let association = self.association
        try await loop.submit { association.close() }.get()
    }
}

private let udpProfile = """
    [General]
    dns-server = 192.0.2.53

    [Proxy]
    Proxy = socks5, 127.0.0.1, {UPSTREAM}, udp-relay=true
    NoUDP = socks5, 127.0.0.1, {UPSTREAM}

    [Rule]
    DOMAIN,direct.example.com,DIRECT
    DOMAIN,proxy.example.com,Proxy
    DOMAIN,reject.example.com,REJECT
    DOMAIN,noudp.example.com,NoUDP
    FINAL,DIRECT
    """

@Suite("UDP routing (06 §10)")
struct UDPRoutingTests {
    private func startEcho(_ harness: RouterHarness) async throws -> (any Channel, UInt16) {
        let channel = try await DatagramBootstrap(group: harness.threads.eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(UDPEcho()) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return (channel, UInt16(channel.localAddress?.port ?? 0))
    }

    private func udpRecord(_ harness: RouterHarness, host: String) async throws -> RequestRecord? {
        _ = await Poll.until {
            ((try? await harness.records()) ?? []).contains { $0.host == host && $0.transport == .udp }
        }
        return try await harness.records().first { $0.host == host && $0.transport == .udp }
    }

    @Test("DIRECT to a real IP and to a Fake IP, a SOCKS5 node with UDP, rejects, nodes without UDP, and DNS")
    func routing() async throws {
        let harness = try await RouterHarness.start(profile: udpProfile)
        let (echo, port) = try await startEcho(harness)
        let client = try await HevUDPClient.open(harness)
        let loopback = IPAddress("127.0.0.1")!

        // 真实 IP：原样往返。
        let real = try #require(try await client.exchange("real", to: .ip(loopback, port: port), expecting: 1))
        #expect(real.0 == "real" && real.1 == .ip(loopback, port: port))

        // Fake IP → DIRECT：本地解析后发往真实地址，回包以 Fake IP 为来源。
        let fakeDirect = try #require(try await harness.queryA("direct.example.com"))
        let direct = try #require(try await client.exchange("fake", to: .ip(fakeDirect, port: port), expecting: 2))
        #expect(direct.0 == "fake" && direct.1 == .ip(fakeDirect, port: port))
        let directRecord = try #require(try await udpRecord(harness, host: "direct.example.com"))
        #expect(directRecord.hostSource == .fakeIP && directRecord.policyChain == ["DIRECT"])
        #expect(directRecord.remoteAddress == "127.0.0.1:\(port)")

        // Fake IP → SOCKS5 节点：以域名交给上游（测试上游原样回显，来源即目标），回包以 Fake IP 为来源。
        let fakeProxy = try #require(try await harness.queryA("proxy.example.com"))
        let proxied = try #require(try await client.exchange("proxied", to: .ip(fakeProxy, port: 5353), expecting: 3))
        #expect(proxied.0 == "proxied" && proxied.1 == .ip(fakeProxy, port: 5353))
        let proxyRecord = try #require(try await udpRecord(harness, host: "proxy.example.com"))
        #expect(proxyRecord.policyChain == ["Proxy"] && proxyRecord.remoteAddress == "proxy.example.com:5353")

        // 拒绝与不支持 UDP 的节点：丢弃并记录。
        let fakeReject = try #require(try await harness.queryA("reject.example.com"))
        try await client.send(ByteBuffer(string: "x"), to: .ip(fakeReject, port: port))
        #expect(try await udpRecord(harness, host: "reject.example.com")?.errorCode == "NET-022")
        let fakeNoUDP = try #require(try await harness.queryA("noudp.example.com"))
        try await client.send(ByteBuffer(string: "x"), to: .ip(fakeNoUDP, port: port))
        #expect(try await udpRecord(harness, host: "noudp.example.com")?.errorCode == "NET-021")

        // 发往隧道 DNS 地址的数据报由 DNS 服务应答。
        var query = DNSMessage(header: DNSHeader(id: 9))
        query.questions = [DNSQuestion(name: DNSName("direct.example.com")!, type: .a)]
        let dns = try #require(
            try await client.exchange(
                String(decoding: query.encode(), as: UTF8.self),
                to: .ip(RuntimeConfiguration.tunnelDNSAddress, port: 53),
                expecting: 4))
        #expect(dns.1 == .ip(RuntimeConfiguration.tunnelDNSAddress, port: 53))
        #expect(client.received.withLockedValue { $0.count } == 4)

        try await client.close()
        let router = harness.router
        #expect(
            await Poll.until { (try? await harness.threads.eventLoop.submit { router.udpAssociationCount }.get()) == 0 }
        )
        try await echo.close()
        try await harness.stop()
    }

    @Test("udp-policy-not-supported-behaviour = DIRECT, block-quic = always, and the association limit")
    func fallbacksAndLimits() async throws {
        let profile = """
            [General]
            dns-server = 192.0.2.53
            udp-policy-not-supported-behaviour = DIRECT
            block-quic = always

            [Proxy]
            NoUDP = socks5, 127.0.0.1, {UPSTREAM}

            [Rule]
            FINAL,NoUDP
            """
        let harness = try await RouterHarness.start(profile: profile)
        let (echo, port) = try await startEcho(harness)
        let client = try await HevUDPClient.open(harness)
        let loopback = IPAddress("127.0.0.1")!

        let reply = try #require(try await client.exchange("fallback", to: .ip(loopback, port: port), expecting: 1))
        #expect(reply.0 == "fallback")
        let records = try await harness.records()
        #expect(records.first?.notes.contains { $0.contains("using DIRECT") } == true)

        // QUIC 长包头发往 443：被 block-quic 拒绝，应用协议记为 QUIC。
        try await client.send(ByteBuffer(bytes: [0xC3, 0, 0, 0, 1, 8, 1, 2]), to: .ip(loopback, port: 443))
        _ = await Poll.until { ((try? await harness.records()) ?? []).contains { $0.errorCode == "NET-022" } }
        let quic = try #require(try await harness.records().first { $0.errorCode == "NET-022" })
        #expect(quic.appProtocol == .quic && quic.notes.contains("block-quic"))

        // 关联数上限：超出的关联立即关闭。
        let router = harness.router
        try await harness.threads.eventLoop.submit { router.udpAssociationLimit = 1 }.get()
        let second = try await HevUDPClient.open(harness)
        try await second.association.closeFuture.get()

        try await client.close()
        try await echo.close()
        try await harness.stop()
    }
}
