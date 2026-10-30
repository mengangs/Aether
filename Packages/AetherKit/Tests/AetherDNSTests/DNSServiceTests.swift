import AetherFoundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import AetherDNS

/// 假上游：记录收到的查询，按脚本应答；`hold` 为 true 时把 promise 留给测试手动完成。
final class MockUpstream: DNSUpstream, @unchecked Sendable {
    let name: String
    let isSystem: Bool
    private let lock = NIOLock()
    private var _queries: [DNSMessage] = []
    private var _held: [(DNSMessage, EventLoopPromise<[UInt8]>)] = []
    var hold = false
    /// 由查询生成应答；返回 nil 表示超时不应答（promise 永不完成）。
    var respond: (DNSMessage) -> DNSMessage?

    init(name: String = "mock", isSystem: Bool = false, respond: @escaping (DNSMessage) -> DNSMessage?) {
        self.name = name
        self.isSystem = isSystem
        self.respond = respond
    }

    var queries: [DNSMessage] { lock.withLock { _queries } }

    func send(_ query: [UInt8], on eventLoop: any EventLoop) -> EventLoopFuture<[UInt8]> {
        guard let message = try? DNSMessage.decode(query) else {
            return eventLoop.makeFailedFuture(DNSError(.dnsMalformedResponse))
        }
        lock.withLock { _queries.append(message) }
        let promise = eventLoop.makePromise(of: [UInt8].self)
        if hold {
            lock.withLock { _held.append((message, promise)) }
        } else if let response = respond(message) {
            promise.succeed(response.encode())
        }
        return promise.futureResult
    }

    /// 完成全部被扣住的查询。
    func release() {
        let held = lock.withLock { () -> [(DNSMessage, EventLoopPromise<[UInt8]>)] in
            defer { _held = [] }
            return _held
        }
        for (message, promise) in held {
            if let response = respond(message) {
                promise.succeed(response.encode())
            }
        }
    }

    /// 标准应答：A → 192.0.2.x，AAAA → 2001:db8::x，TTL 可调；`nx` 中的域名返回 NXDOMAIN。
    static func standard(ttl: UInt32 = 300, nx: Set<String> = [], soaMinimum: UInt32? = nil) -> (DNSMessage) ->
        DNSMessage?
    {
        { query in
            guard let question = query.questions.first else { return nil }
            if nx.contains(question.name.normalized) {
                var response = DNSMessage.response(to: query, code: .nameError)
                if let soaMinimum {
                    response.authorities = [soa(minimum: soaMinimum)]
                }
                return response
            }
            switch question.type {
            case .a:
                return DNSMessage.response(
                    to: query,
                    answers: [
                        DNSResourceRecord(name: question.name, type: .a, ttl: ttl, data: .a(IPv4Address(192, 0, 2, 80)))
                    ])
            case .aaaa:
                return DNSMessage.response(
                    to: query,
                    answers: [
                        DNSResourceRecord(
                            name: question.name, type: .aaaa, ttl: ttl, data: .aaaa(IPv6Address("2001:db8::80")!))
                    ])
            default:
                var response = DNSMessage.response(to: query)
                if let soaMinimum {
                    response.authorities = [soa(minimum: soaMinimum)]
                }
                return response
            }
        }
    }

    static func soa(minimum: UInt32) -> DNSResourceRecord {
        DNSResourceRecord(
            name: DNSName("example.com")!, type: .soa, ttl: 3600,
            data: .soa(
                DNSSOA(
                    primaryServer: DNSName("ns.example.com")!, responsibleMailbox: DNSName("admin.example.com")!,
                    serial: 1, refresh: 1, retry: 1, expire: 1, minimum: minimum)))
    }
}

private struct Harness {
    let loop: EmbeddedEventLoop
    let service: DNSService
    let upstream: MockUpstream

    init(
        configure: (inout DNSConfiguration) -> Void = { _ in },
        upstream: MockUpstream = MockUpstream(respond: MockUpstream.standard())
    ) {
        loop = EmbeddedEventLoop()
        var configuration = DNSConfiguration()
        configuration.servers = ["192.0.2.53"]
        configure(&configuration)
        self.upstream = upstream
        let counter = NIOLockedValueBox<UInt16>(100)
        service = DNSService(
            configuration: configuration,
            environment: .init(
                eventLoop: loop,
                transactionID: {
                    counter.withLockedValue {
                        $0 &+= 1
                        return $0
                    }
                },
                makeUpstream: { _ in upstream }
            ))
    }

    func query(
        _ domain: String, _ type: DNSRecordType, id: UInt16 = 0x4242, edns: UInt16? = nil,
        transport: DNSService.Transport = .udp
    )
        throws -> DNSMessage
    {
        var message = DNSMessage(header: DNSHeader(id: id))
        message.questions = [DNSQuestion(name: DNSName(domain)!, type: type)]
        if let edns {
            message.additionals = [DNSEDNS(udpPayloadSize: edns).record]
        }
        let future = service.answer(message.encode(), transport: transport)
        loop.run()
        let bytes = try #require(try future.wait())
        return try DNSMessage.decode(bytes)
    }
}

@Suite("DNS answer flow")
struct DNSAnswerFlowTests {
    @Test("[Host] static addresses answer A and AAAA with TTL 60 before Fake IP")
    func hostFirst() throws {
        let harness = Harness { config in
            config.hosts = [
                HostEntry(
                    pattern: "router.example.com",
                    value: .addresses([IPAddress("192.0.2.1")!, IPAddress("2001:db8::1")!]))
            ]
        }
        let a = try harness.query("router.example.com", .a)
        #expect(a.answers.map(\.address) == [IPAddress("192.0.2.1")])
        #expect(a.answers.first?.ttl == 60)
        #expect(a.header.id == 0x4242 && a.header.isResponse)
        let aaaa = try harness.query("router.example.com", .aaaa)
        #expect(aaaa.answers.map(\.address) == [IPAddress("2001:db8::1")])
        #expect(harness.upstream.queries.isEmpty)
    }

    @Test("Fake IP answers A with TTL 1, stable per domain, and PTR maps back")
    func fakeIP() throws {
        let harness = Harness()
        let first = try harness.query("www.example.com", .a)
        let second = try harness.query("WWW.example.com", .a)
        #expect(first.answers.first?.ttl == 1)
        let address = try #require(first.answers.first?.address)
        #expect(second.answers.first?.address == address)
        #expect(CIDR("198.18.0.0/15")!.contains(address))
        #expect(harness.service.domain(forFakeIP: address) == "www.example.com")

        let octets = address.bytes.reversed().map(String.init).joined(separator: ".")
        let ptr = try harness.query("\(octets).in-addr.arpa", .ptr)
        #expect(ptr.answers.first?.data == .ptr(DNSName("www.example.com")!))
        let unknown = try harness.query("250.250.19.198.in-addr.arpa", .ptr)
        #expect(unknown.header.responseCode == .nameError)
        #expect(harness.upstream.queries.isEmpty)
    }

    @Test("Real IP exceptions, AAAA with ipv6 off, HTTPS/SVCB in fake mode")
    func exceptions() throws {
        let harness = Harness()
        let real = try harness.query("captive.apple.com", .a)
        #expect(real.answers.first?.address == IPAddress("192.0.2.80"))
        #expect(harness.upstream.queries.count == 1)

        let aaaa = try harness.query("www.example.com", .aaaa)
        #expect(aaaa.header.responseCode == .noError && aaaa.answers.isEmpty)
        let https = try harness.query("www.example.com", .https)
        #expect(https.header.responseCode == .noError && https.answers.isEmpty)
        let svcb = try harness.query("www.example.com", .svcb)
        #expect(svcb.answers.isEmpty)
        #expect(harness.upstream.queries.count == 1)

        // 其它类型照常走上游。
        _ = try harness.query("www.example.com", .txt)
        #expect(harness.upstream.queries.count == 2)
    }

    @Test("Real IP mode forwards A upstream and fills the reverse table")
    func realIPMode() throws {
        let harness = Harness {
            $0.mode = .realIP
            $0.ipv6 = true
        }
        let a = try harness.query("www.example.com", .a)
        #expect(a.answers.first?.address == IPAddress("192.0.2.80"))
        #expect(harness.service.domain(forRealIP: IPAddress("192.0.2.80")!) == "www.example.com")
        let aaaa = try harness.query("www.example.com", .aaaa)
        #expect(aaaa.answers.first?.address == IPAddress("2001:db8::80"))
    }

    @Test("Malformed queries: FORMERR with the same ID, or dropped when too short")
    func malformed() throws {
        let harness = Harness()
        var twoQuestions = DNSMessage(header: DNSHeader(id: 77))
        twoQuestions.questions = [
            DNSQuestion(name: DNSName("a.example")!, type: .a), DNSQuestion(name: DNSName("b.example")!, type: .a),
        ]
        let future = harness.service.answer(twoQuestions.encode(), transport: .udp)
        let response = try DNSMessage.decode(try #require(try future.wait()))
        #expect(response.header.responseCode == .formatError && response.header.id == 77)

        let garbage: [UInt8] = [0, 88, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xFF]
        let garbageResponse = try DNSMessage.decode(
            try #require(try harness.service.answer(garbage, transport: .udp).wait()))
        #expect(garbageResponse.header.responseCode == .formatError && garbageResponse.header.id == 88)

        #expect(try harness.service.answer([1, 2, 3], transport: .udp).wait() == nil)
    }

    @Test("Large upstream answers are truncated for UDP but not TCP")
    func truncation() throws {
        let upstream = MockUpstream { query in
            let records = (0..<40).map { _ in
                DNSResourceRecord(
                    name: query.questions[0].name, type: .txt, ttl: 60,
                    data: .opaque([30] + Array(repeating: 0x41, count: 30)))
            }
            return DNSMessage.response(to: query, answers: records)
        }
        let harness = Harness(upstream: upstream)
        let udp = try harness.query("big.example.com", .txt)
        #expect(udp.header.isTruncated && udp.answers.isEmpty)
        let tcp = try harness.query("big.example.com", .txt, transport: .tcp)
        #expect(!tcp.header.isTruncated && tcp.answers.count == 40)
        let edns = try harness.query("big.example.com", .txt, edns: 4096)
        #expect(edns.header.isTruncated)
    }
}

@Suite("DNS cache")
struct DNSCacheTests {
    @Test("Cached answers age their TTL and expire")
    func positive() throws {
        let harness = Harness { $0.mode = .realIP }
        _ = try harness.query("www.example.com", .a, id: 1)
        harness.loop.advanceTime(by: .seconds(100))
        let cached = try harness.query("www.example.com", .a, id: 2)
        #expect(cached.header.id == 2)
        #expect(cached.answers.first?.ttl == 200)
        #expect(harness.upstream.queries.count == 1)
        harness.loop.advanceTime(by: .seconds(201))
        _ = try harness.query("www.example.com", .a, id: 3)
        #expect(harness.upstream.queries.count == 2)
    }

    @Test("Positive TTL has a 10 s floor")
    func floor() throws {
        let harness = Harness(
            configure: { $0.mode = .realIP }, upstream: MockUpstream(respond: MockUpstream.standard(ttl: 2)))
        _ = try harness.query("short.example.com", .a)
        harness.loop.advanceTime(by: .seconds(9))
        _ = try harness.query("short.example.com", .a)
        #expect(harness.upstream.queries.count == 1)
        harness.loop.advanceTime(by: .seconds(2))
        _ = try harness.query("short.example.com", .a)
        #expect(harness.upstream.queries.count == 2)
    }

    @Test("Negative caching follows SOA within 10–300 s; SERVFAIL is cached 5 s")
    func negative() throws {
        let nx = MockUpstream(respond: MockUpstream.standard(nx: ["gone.example.com"], soaMinimum: 60))
        let harness = Harness(configure: { $0.mode = .realIP }, upstream: nx)
        #expect(try harness.query("gone.example.com", .a).header.responseCode == .nameError)
        harness.loop.advanceTime(by: .seconds(59))
        _ = try harness.query("gone.example.com", .a)
        #expect(nx.queries.count == 1)
        harness.loop.advanceTime(by: .seconds(2))
        _ = try harness.query("gone.example.com", .a)
        #expect(nx.queries.count == 2)

        let noSOA = MockUpstream(respond: MockUpstream.standard(nx: ["gone.example.com"]))
        let second = Harness(configure: { $0.mode = .realIP }, upstream: noSOA)
        _ = try second.query("gone.example.com", .a)
        second.loop.advanceTime(by: .seconds(11))
        _ = try second.query("gone.example.com", .a)
        #expect(noSOA.queries.count == 2)

        let failing = MockUpstream { DNSMessage.response(to: $0, code: .serverFailure) }
        let third = Harness(configure: { $0.mode = .realIP }, upstream: failing)
        #expect(try third.query("www.example.com", .a).header.responseCode == .serverFailure)
        third.loop.advanceTime(by: .seconds(4))
        _ = try third.query("www.example.com", .a)
        #expect(failing.queries.count == 1)
        third.loop.advanceTime(by: .seconds(2))
        _ = try third.query("www.example.com", .a)
        #expect(failing.queries.count == 2)
    }

    @Test("Concurrent identical queries share one upstream request")
    func coalescing() throws {
        let upstream = MockUpstream(respond: MockUpstream.standard())
        upstream.hold = true
        let harness = Harness(configure: { $0.mode = .realIP }, upstream: upstream)
        var query = DNSMessage(header: DNSHeader(id: 1))
        query.questions = [DNSQuestion(name: DNSName("www.example.com")!, type: .a)]
        let first = harness.service.answer(query.encode(), transport: .udp)
        query.header.id = 2
        let second = harness.service.answer(query.encode(), transport: .udp)
        let resolved = harness.service.resolve("www.example.com", type: .a, purpose: .routing)
        #expect(upstream.queries.count == 1)
        upstream.release()
        harness.loop.run()
        #expect(try DNSMessage.decode(try #require(try first.wait())).header.id == 1)
        #expect(try DNSMessage.decode(try #require(try second.wait())).header.id == 2)
        #expect(try resolved.wait() == [IPAddress("192.0.2.80")!])
    }

    @Test("Network changes drop only entries from the system upstream")
    func networkChange() throws {
        let system = MockUpstream(name: "system", isSystem: true, respond: MockUpstream.standard())
        let loop = EmbeddedEventLoop()
        var configuration = DNSConfiguration()
        configuration.mode = .realIP
        configuration.servers = ["system"]
        configuration.hosts = [HostEntry(pattern: "pinned.example.com", value: .upstream("192.0.2.53"))]
        let plain = MockUpstream(name: "plain", respond: MockUpstream.standard())
        let service = DNSService(
            configuration: configuration,
            environment: .init(eventLoop: loop, makeUpstream: { spec in spec == .system ? system : plain }))
        _ = try service.resolve("www.example.com", type: .a, purpose: .direct).wait()
        _ = try service.resolve("pinned.example.com", type: .a, purpose: .direct).wait()
        #expect(service.cacheCount == 2)
        service.networkChanged()
        #expect(service.cacheCount == 1)
        _ = try service.resolve("pinned.example.com", type: .a, purpose: .direct).wait()
        #expect(plain.queries.count == 1)
        _ = try service.resolve("www.example.com", type: .a, purpose: .direct).wait()
        #expect(system.queries.count == 2)
        service.flushCache()
        #expect(service.cacheCount == 0)
    }
}

@Suite("DNS resolution")
struct DNSResolutionTests {
    @Test("Resolution never returns Fake IPs and honours [Host]")
    func resolution() throws {
        let harness = Harness { config in
            config.hosts = [
                HostEntry(pattern: "static.example.com", value: .addresses([IPAddress("192.0.2.7")!])),
                HostEntry(pattern: "alias.example.com", value: .alias("static.example.com")),
            ]
        }
        #expect(
            try harness.service.resolve("www.example.com", type: .a, purpose: .routing).wait() == [
                IPAddress("192.0.2.80")!
            ])
        #expect(
            try harness.service.resolve("static.example.com", type: .a, purpose: .direct).wait() == [
                IPAddress("192.0.2.7")!
            ])
        #expect(
            try harness.service.resolve("alias.example.com", type: .a, purpose: .direct).wait() == [
                IPAddress("192.0.2.7")!
            ])
        #expect(try harness.service.resolve("static.example.com", type: .aaaa, purpose: .direct).wait() == [])
        #expect(
            try harness.service.resolve("192.0.2.9", type: .a, purpose: .direct).wait() == [IPAddress("192.0.2.9")!])
        let all = try harness.service.resolveAll("www.example.com", purpose: .routing).wait()
        #expect(all == [IPAddress("192.0.2.80")!, IPAddress("2001:db8::80")!])
        #expect(harness.service.domain(forRealIP: IPAddress("192.0.2.80")!) == "www.example.com")
    }

    @Test("NXDOMAIN and SERVFAIL map to DNS-003 and DNS-002")
    func errors() throws {
        let harness = Harness(upstream: MockUpstream(respond: MockUpstream.standard(nx: ["gone.example.com"])))
        #expect(throws: DNSError(.dnsNameError, "gone.example.com does not exist")) {
            try harness.service.resolve("gone.example.com", type: .a, purpose: .routing).wait()
        }
        let failing = Harness(upstream: MockUpstream { DNSMessage.response(to: $0, code: .serverFailure) })
        #expect(throws: DNSError(.dnsServerFailure, "Upstream answered SERVFAIL")) {
            try failing.service.resolve("www.example.com", type: .a, purpose: .routing).wait()
        }
    }
}

@Suite("DNS upstream group")
struct DNSUpstreamGroupTests {
    @Test("The first NOERROR wins over an earlier SERVFAIL")
    func firstSuccess() throws {
        let loop = EmbeddedEventLoop()
        let failing = MockUpstream(name: "failing") { DNSMessage.response(to: $0, code: .serverFailure) }
        let slow = MockUpstream(name: "slow", respond: MockUpstream.standard())
        slow.hold = true
        let group = DNSUpstreamGroup(identifier: "plain", upstreams: [failing, slow], eventLoop: loop)
        var query = DNSMessage(header: DNSHeader(id: 5))
        query.questions = [DNSQuestion(name: DNSName("www.example.com")!, type: .a)]
        let future = group.query(query.encode())
        loop.run()
        slow.release()
        loop.run()
        let answer = try future.wait()
        #expect(answer.upstream == "slow")
        #expect(answer.responseCode == .noError)
        let statistics = group.upstreamStatistics
        #expect(statistics.first { $0.name == "failing" }?.failures == 1)
        #expect(statistics.first { $0.name == "slow" }?.recentDurationsMs.count == 1)
    }

    @Test("When every upstream fails the last answer is returned; silence times out after 5 s")
    func fallbackAndTimeout() throws {
        let loop = EmbeddedEventLoop()
        let refusing = MockUpstream(name: "refusing") { DNSMessage.response(to: $0, code: .refused) }
        let group = DNSUpstreamGroup(identifier: "plain", upstreams: [refusing], eventLoop: loop)
        var query = DNSMessage(header: DNSHeader(id: 5))
        query.questions = [DNSQuestion(name: DNSName("www.example.com")!, type: .a)]
        #expect(try group.query(query.encode()).wait().responseCode == .refused)

        let silent = MockUpstream(name: "silent") { _ in nil }
        let quiet = DNSUpstreamGroup(identifier: "plain", upstreams: [silent], eventLoop: loop)
        let pending = quiet.query(query.encode())
        let done = NIOLockedValueBox(false)
        pending.whenComplete { _ in done.withLockedValue { $0 = true } }
        loop.advanceTime(by: .seconds(4))
        #expect(!done.withLockedValue { $0 })
        loop.advanceTime(by: .seconds(1))
        #expect(throws: DNSError.self) { try pending.wait() }

        // 应答方把超时转换为 SERVFAIL。
        let harness = Harness(configure: { $0.mode = .realIP }, upstream: silent)
        var client = DNSMessage(header: DNSHeader(id: 9))
        client.questions = [DNSQuestion(name: DNSName("www.example.com")!, type: .a)]
        let answer = harness.service.answer(client.encode(), transport: .udp)
        harness.loop.advanceTime(by: .seconds(5))
        #expect(try DNSMessage.decode(try #require(try answer.wait())).header.responseCode == .serverFailure)
    }
}
