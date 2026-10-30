import AetherFoundation
import AetherHTTP
import AetherOutbound
import AetherProfile
import AetherRules
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import AetherEngine

private let groupsProfile = """
    [General]
    proxy-test-url = http://test.example.com/generate_204
    test-timeout = 5

    [Proxy]
    A = socks5, 192.0.2.1, 1080
    B = socks5, 192.0.2.2, 1080
    C = socks5, 192.0.2.3, 1080

    [Proxy Group]
    U = url-test, A, B, C, tolerance=50
    F = fallback, A, B, C
    L = load-balance, A, B, C, persistent=true
    R = load-balance, A, B, C
    E = url-test, A, B, evaluate-before-use=true
    N = select, U, DIRECT

    [Rule]
    DOMAIN,eval.example.com,E
    FINAL,U
    """

private func compile(_ text: String) -> RuntimeConfiguration {
    RuntimeConfiguration.compile(ProfileResolver.resolve(profileText: text, fileName: "t.conf"))
}

/// 可手动推进的时钟。
private final class ManualDate: Sendable {
    private let value = NIOLockedValueBox(Date(timeIntervalSince1970: 1_793_347_200))
    var now: Date { value.withLockedValue { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLockedValue { $0.addTimeInterval(seconds) } }
}

private func identity(_ name: String, _ configuration: RuntimeConfiguration) -> String {
    guard case .proxy(let node) = configuration.policies[name] else { return name }
    return node.identity
}

@Suite("Automatic policy groups (06 §9.1)")
struct PolicyGroupSelectionTests {
    private func setup(random: @escaping @Sendable (Int) -> Int = { _ in 0 }) -> (
        PolicyRegistry, RuntimeConfiguration, ManualDate
    ) {
        let clock = ManualDate()
        let configuration = compile(groupsProfile)
        let registry = PolicyRegistry(clock: { clock.now }, random: random)
        return (registry, configuration, clock)
    }

    private func record(
        _ registry: PolicyRegistry, _ configuration: RuntimeConfiguration, _ clock: ManualDate,
        _ results: [String: Int?]
    ) {
        for (name, latency) in results {
            registry.record(
                LatencyResult(
                    latencyMs: latency, errorCode: latency == nil ? "NET-002" : nil, at: clock.now, networkRevision: 0),
                for: identity(name, configuration))
        }
    }

    private func chain(
        _ registry: PolicyRegistry, _ name: String, _ configuration: RuntimeConfiguration,
        host: String? = nil
    ) -> [String] {
        (try? registry.resolve(name, in: configuration, host: host).chain) ?? []
    }

    @Test("Without results automatic groups use their first member and ask for a test; evaluate-before-use waits")
    func noResults() throws {
        let (registry, configuration, _) = setup()
        #expect(chain(registry, "U", configuration) == ["U", "A"])
        #expect(chain(registry, "N", configuration) == ["N", "U", "A"])
        #expect(Set(registry.takePendingGroups()) == ["U"])
        #expect(registry.takePendingGroups().isEmpty)
        #expect(throws: PolicyAwaitingEvaluation.self) { try registry.resolve("E", in: configuration) }
        #expect(registry.lastUsed("U") != nil)
    }

    @Test(
        "url-test picks the lowest latency and switches only when the gain exceeds the tolerance or the current fails")
    func urlTest() {
        let (registry, configuration, clock) = setup()
        record(registry, configuration, clock, ["A": 300, "B": 100, "C": nil])
        #expect(chain(registry, "U", configuration) == ["U", "B"])
        // A 变为 70：比当前的 100 只低 30（< 50），不切换。
        record(registry, configuration, clock, ["A": 70])
        #expect(chain(registry, "U", configuration) == ["U", "B"])
        // A 变为 40：低 60，切换。
        record(registry, configuration, clock, ["A": 40])
        #expect(chain(registry, "U", configuration) == ["U", "A"])
        // 当前成员失败：立即切到最佳可用成员。
        record(registry, configuration, clock, ["A": nil])
        #expect(chain(registry, "U", configuration) == ["U", "B"])
        // 全部失败：回到第一个成员。
        record(registry, configuration, clock, ["B": nil])
        #expect(chain(registry, "U", configuration) == ["U", "A"])
    }

    @Test("fallback takes the first available member in order; passive failures degrade a node for 60 s")
    func fallbackAndDegradation() {
        let (registry, configuration, clock) = setup()
        record(registry, configuration, clock, ["A": nil, "B": 200, "C": 50])
        #expect(chain(registry, "F", configuration) == ["F", "B"])
        let b = identity("B", configuration)
        // 10 秒窗口外的失败不累计。
        #expect(!registry.recordFailure(b))
        clock.advance(11)
        #expect(!registry.recordFailure(b))
        #expect(!registry.recordFailure(b))
        #expect(registry.recordFailure(b))
        #expect(registry.isDegraded(b))
        #expect(chain(registry, "F", configuration) == ["F", "C"])
        clock.advance(61)
        #expect(!registry.isDegraded(b))
        #expect(chain(registry, "F", configuration) == ["F", "B"])
        // 连接成功清空失败计数。
        registry.recordFailure(b)
        registry.recordFailure(b)
        registry.recordSuccess(b)
        #expect(!registry.recordFailure(b))
    }

    @Test("load-balance: persistent maps a host to a stable member (HRW); otherwise random among available members")
    func loadBalance() {
        let picks = NIOLockedValueBox<[Int]>([])
        let (registry, configuration, clock) = setup { count in
            picks.withLockedValue { $0.append(count) }
            return 1
        }
        record(registry, configuration, clock, ["A": 100, "B": 100, "C": 100])
        let hosts = (0..<20).map { "h\($0).example.com" }
        let first = hosts.map { chain(registry, "L", configuration, host: $0).last }
        #expect(first == hosts.map { chain(registry, "L", configuration, host: $0).last })
        #expect(Set(first.compactMap { $0 }).count > 1, "hosts spread over members")
        // 某个成员不可用时，映射到其它成员的主机不受影响。
        record(registry, configuration, clock, ["C": nil])
        for (host, member) in zip(hosts, first) where member != "C" {
            #expect(chain(registry, "L", configuration, host: host).last == member)
        }
        #expect(chain(registry, "R", configuration).last == "B")
        #expect(picks.withLockedValue { $0 }.last == 2)
    }

    @Test("Reload keeps results by node identity and forgets removed nodes")
    func migration() {
        let (registry, configuration, clock) = setup()
        record(registry, configuration, clock, ["A": 300, "B": 100])
        let changed = compile(
            groupsProfile.replacingOccurrences(of: "C = socks5, 192.0.2.3, 1080\n", with: "")
                .replacingOccurrences(of: ", C", with: "").replacingOccurrences(
                    of: "A = socks5, 192.0.2.1", with: "A = socks5, 192.0.2.9"))
        registry.migrate(to: changed)
        #expect(registry.latest(for: identity("B", configuration))?.latencyMs == 100)
        #expect(registry.latest(for: identity("A", configuration)) == nil)
        #expect(chain(registry, "U", changed) == ["U", "B"])
    }
}

// MARK: - 测速

/// 测试用连接器：按设定的"延迟"推进单调时钟后连到回环源站（忽略目标）；`fail` 时以 NET-001 失败；
/// `gate` 时把连接挂起，直到测试放行（用于观察并发上限）。
private final class FakeConnector: OutboundConnector, @unchecked Sendable {
    let name: String
    let capabilities: OutboundCapabilities = [.tcp]
    let delayMs: Int64
    let fail: Bool
    let originPort: Int
    let clock: MonotonicClock
    let gate: Gate?
    let connects = NIOLockedValueBox(0)

    init(name: String, delayMs: Int64, fail: Bool = false, originPort: Int, clock: MonotonicClock, gate: Gate? = nil) {
        self.name = name
        self.delayMs = delayMs
        self.fail = fail
        self.originPort = originPort
        self.clock = clock
        self.gate = gate
    }

    func connect(to destination: Destination, context: DialContext) -> EventLoopFuture<any Channel> {
        connects.withLockedValue { $0 += 1 }
        if fail {
            return context.eventLoop.makeFailedFuture(NetworkError(.netConnectionRefused, "refused"))
        }
        let open = { @Sendable () -> EventLoopFuture<any Channel> in
            self.clock.advance(milliseconds: self.delayMs)
            return ClientBootstrap(group: context.eventLoop).channelOption(.autoRead, value: false)
                .connect(host: "127.0.0.1", port: self.originPort).map { $0 as any Channel }
        }
        guard let gate else { return open() }
        return gate.wait(on: context.eventLoop).flatMap { open() }
    }
}

final class MonotonicClock: Sendable {
    private let offset = NIOLockedValueBox<Int64>(0)
    private let base = NIODeadline.now()
    func advance(milliseconds: Int64) { offset.withLockedValue { $0 += milliseconds } }
    func now() -> NIODeadline { base + .milliseconds(offset.withLockedValue { $0 }) }
}

/// 挂起连接直到放行；记录同时挂起的最大数量。
final class Gate: Sendable {
    private let state = NIOLockedValueBox<(waiting: [EventLoopPromise<Void>], open: Bool, peak: Int)>(([], false, 0))
    var waiting: Int { state.withLockedValue { $0.waiting.count } }
    var peak: Int { state.withLockedValue { $0.peak } }

    func wait(on loop: any EventLoop) -> EventLoopFuture<Void> {
        let promise = loop.makePromise(of: Void.self)
        let released = state.withLockedValue { state -> Bool in
            if state.open { return true }
            state.waiting.append(promise)
            state.peak = max(state.peak, state.waiting.count)
            return false
        }
        if released { promise.succeed(()) }
        return promise.futureResult
    }

    func release() {
        let waiting = state.withLockedValue { state -> [EventLoopPromise<Void>] in
            state.open = true
            defer { state.waiting.removeAll() }
            return state.waiting
        }
        for promise in waiting {
            promise.succeed(())
        }
    }
}

@Suite("Latency tests (06 §9.2)")
struct PolicyTesterTests {
    /// 用测试连接器替换配置中的节点。
    private func configuration(nodes: [String: FakeConnector], text: String) -> RuntimeConfiguration {
        let base = compile(text)
        var policies = base.policies
        for (name, connector) in nodes {
            guard case .proxy(var node) = policies[name] else { continue }
            node.connector = connector
            policies[name] = .proxy(node)
        }
        return RuntimeConfiguration(
            revision: base.revision, profileID: "", profileName: "", general: base.general, program: base.program,
            policies: policies, groupOrder: base.groupOrder, proxyOrder: base.proxyOrder, dns: base.dns,
            hijackDNS: base.hijackDNS, notes: base.notes)
    }

    private func start(_ configuration: RuntimeConfiguration, clock: MonotonicClock, concurrency: Int = 8) async throws
        -> Engine
    {
        var options = Engine.Options()
        options.testerSettings.concurrency = concurrency
        options.socksCredentials = nil
        options.httpProxy = nil
        options.periodicTests = false
        options.monotonicNow = { clock.now() }
        return try await Engine.start(configuration: configuration, options: options)
    }

    @Test("Group tests measure each member through its connector; url-test then follows the results")
    func groupTest() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await HTTPTestOrigin.start(group: group)
        let clock = MonotonicClock()
        let nodes = [
            "A": FakeConnector(name: "A", delayMs: 300, originPort: origin.port, clock: clock),
            "B": FakeConnector(name: "B", delayMs: 120, originPort: origin.port, clock: clock),
            "C": FakeConnector(name: "C", delayMs: 0, fail: true, originPort: origin.port, clock: clock),
        ]
        // 共用一个假时钟：逐个测速，使每次测得的延迟只含该节点的推进量。
        let engine = try await start(configuration(nodes: nodes, text: groupsProfile), clock: clock, concurrency: 1)
        let router = engine.router
        // 首次使用没有结果：解析到 A 并登记待测；tick 测试待测组。
        let first = try await engine.eventLoop.submit {
            try router.dependencies.policies.resolve("U", in: router.configuration).chain
        }.get()
        #expect(first == ["U", "A"])
        try await engine.eventLoop.flatSubmit { () -> EventLoopFuture<Void> in
            router.tester?.tick()
            return router.tester?.testGroup("U") ?? router.eventLoop.makeSucceededVoidFuture()
        }.get()
        let configuration = try await engine.eventLoop.submit { router.configuration }.get()
        let registry = engine.policies
        #expect(registry.latest(for: identity("A", configuration))?.latencyMs == 300)
        #expect(registry.latest(for: identity("B", configuration))?.latencyMs == 120)
        #expect(registry.latest(for: identity("C", configuration))?.errorCode == "NET-001")
        let after = try await engine.eventLoop.submit { try registry.resolve("U", in: router.configuration).chain }
            .get()
        #expect(after == ["U", "B"])
        // 同一节点的测速合并：两个组同时测，每个节点只连一次。
        let before = nodes["A"]?.connects.withLockedValue { $0 } ?? 0
        try await engine.eventLoop.flatSubmit {
            EventLoopFuture.andAllComplete(
                [router.tester!.testGroup("U"), router.tester!.testGroup("F")], on: router.eventLoop)
        }.get()
        #expect(nodes["A"]?.connects.withLockedValue { $0 } == before + 1)

        // evaluate-before-use：判定时先测速再解析。
        let routeContext = RouteContext(host: Hostname("eval.example.com"), destinationPort: 443)
        let decision = try await engine.eventLoop.flatSubmit {
            router.decide(routeContext, configuration: router.configuration)
        }.get()
        #expect(decision.resolution.chain == ["E", "B"])
        await engine.stop()
        try await origin.close()
        try await group.shutdownGracefully()
    }

    @Test("Manual tasks report per-node results; at most 8 tests run at once")
    func manualTaskAndConcurrency() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let origin = try await HTTPTestOrigin.start(group: group)
        let clock = MonotonicClock()
        let gate = Gate()
        var text = "[General]\nproxy-test-url = http://test.example.com/generate_204\n\n[Proxy]\n"
        var nodes: [String: FakeConnector] = [:]
        for index in 0..<12 {
            text += "N\(index) = socks5, 192.0.2.\(index + 10), 1080\n"
            nodes["N\(index)"] = FakeConnector(
                name: "N\(index)", delayMs: Int64(index), originPort: origin.port, clock: clock, gate: gate)
        }
        text += "\n[Rule]\nFINAL,DIRECT\n"
        let engine = try await start(configuration(nodes: nodes, text: text), clock: clock)
        let router = engine.router
        let id = try await engine.eventLoop.submit { try router.tester!.startTask(names: nil, group: nil) }.get()
        #expect(await Poll.until { gate.waiting == 8 })
        #expect(gate.peak == 8)
        gate.release()
        #expect(
            await Poll.until {
                (try? await engine.eventLoop.submit { router.tester?.task(id)?.done ?? false }.get()) == true
            })
        let task = try #require(try await engine.eventLoop.submit { router.tester?.task(id) }.get())
        #expect(task.names.count == 12)
        #expect(task.results.values.allSatisfy { $0.succeeded })
        #expect(gate.peak == 8)
        await #expect(throws: (any Error).self) {
            try await engine.eventLoop.submit { try router.tester!.startTask(names: ["Missing"], group: nil) }.get()
        }
        await engine.stop()
        try await origin.close()
        try await group.shutdownGracefully()
    }

    @Test("Test URL parsing")
    func targets() throws {
        let plain = try #require(HTTPProbeTargetShim.parse("http://test.example.com/generate_204?x=1"))
        #expect(plain == ["false", "test.example.com", "80", "/generate_204?x=1"])
        let secure = try #require(HTTPProbeTargetShim.parse("https://[2001:db8::1]:8443"))
        #expect(secure == ["true", "2001:db8::1", "8443", "/"])
        #expect(HTTPProbeTargetShim.parse("ftp://test.example.com/") == nil)
    }
}

/// 把 `HTTPProbe.Target` 展开成字符串数组，便于比较。
private enum HTTPProbeTargetShim {
    static func parse(_ url: String) -> [String]? {
        guard let target = HTTPProbe.Target(url) else { return nil }
        return [String(target.secure), target.host, String(target.port), target.path]
    }
}
