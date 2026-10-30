import AetherFoundation
import AetherHTTP
import AetherIPC
import AetherOutbound
import Foundation
import NIOCore

/// 测速（docs/06 §9.2）：经各节点请求测速 URL，结果写入 `PolicyRegistry`。绑定到数据面 EventLoop。
///
/// - 自动组（`url-test` / `fallback` / `load-balance`）在"活跃"时（30 分钟内被流量使用过，或 App 正在展示）
///   按 `interval` 周期测速；首次使用而没有结果的组立即测速；不活跃的组不测速。
/// - 网络修订号变化后，结果按修订号视为过期，活跃组在去抖 2 秒后重测。
/// - 被动失败使节点进入降级期时，含该节点的活跃组重测。
/// - 全局并发上限 8，等待队列上限 256（溢出的测速直接以失败结束）；同一节点同时只有一个测速（合并）。
/// - 手动测速（IPC `testPolicies`）返回任务 ID，结果逐个写入，App 以 `getTestResults` 轮询；最多保留 16 个任务。
public final class PolicyTester: @unchecked Sendable {
    public struct Settings: Sendable {
        public var concurrency = 8
        public var queueLimit = 256
        public var activeWindow: TimeInterval = 30 * 60
        public var tickInterval = TimeAmount.seconds(5)
        public var networkDebounce = TimeAmount.seconds(2)
        public static let taskLimit = 16

        public init() {}
    }

    /// 手动测速任务。
    public struct TaskState: Sendable {
        public var id: UInt64
        /// 节点名（含 `DIRECT`），按请求顺序。
        public var names: [String]
        public var results: [String: LatencyResult] = [:]
        public var done: Bool { results.count >= names.count }
    }

    public let eventLoop: any EventLoop
    private let router: Router
    private let settings: Settings
    private let clock: @Sendable () -> Date
    private let now: @Sendable () -> NIODeadline
    private let networkRevision: @Sendable () -> UInt64

    private var running = 0
    private var queue = CircularBuffer<() -> Void>()
    private var inFlight: [String: EventLoopFuture<LatencyResult>] = [:]
    private var lastGroupTest: [String: Date] = [:]
    private var lastRevision: UInt64
    private var tasks: [UInt64: TaskState] = [:]
    private var nextTaskID: UInt64 = 1
    private var ticker: RepeatedTask?
    private var debounce: Scheduled<Void>?

    public init(
        router: Router, settings: Settings = Settings(), clock: @escaping @Sendable () -> Date = { Date() },
        now: @escaping @Sendable () -> NIODeadline = { .now() },
        networkRevision: @escaping @Sendable () -> UInt64 = { 0 }
    ) {
        self.router = router
        eventLoop = router.eventLoop
        self.settings = settings
        self.clock = clock
        self.now = now
        self.networkRevision = networkRevision
        lastRevision = networkRevision()
    }

    private var registry: PolicyRegistry { router.dependencies.policies }

    /// 启动周期检查（每 `tickInterval` 一次）。
    public func start() {
        eventLoop.execute {
            guard self.ticker == nil else { return }
            self.ticker = self.eventLoop.scheduleRepeatedTask(
                initialDelay: self.settings.tickInterval, delay: self.settings.tickInterval
            ) { _ in self.tick() }
        }
    }

    public func stop() {
        eventLoop.execute {
            self.ticker?.cancel()
            self.ticker = nil
            self.debounce?.cancel()
            self.debounce = nil
        }
    }

    // MARK: - 调度

    /// 周期检查：待测组立即测；活跃且到期（或结果已过期）的自动组重测。
    public func tick() {
        eventLoop.preconditionInEventLoop()
        let configuration = router.configuration
        for name in registry.takePendingGroups() {
            _ = testGroup(name)
        }
        let date = clock()
        let revision = networkRevision()
        for name in configuration.groupOrder {
            guard case .group(let group) = configuration.policies[name], group.type.isAutomatic,
                isActive(name, at: date)
            else { continue }
            let due = lastGroupTest[name].map { date.timeIntervalSince($0) >= group.interval } ?? true
            if due || hasStaleResults(group, revision: revision) {
                _ = testGroup(name)
            }
        }
    }

    private func isActive(_ group: String, at date: Date) -> Bool {
        guard let used = registry.lastUsed(group) else { return false }
        return date.timeIntervalSince(used) < settings.activeWindow
    }

    private func hasStaleResults(_ group: PolicyGroup, revision: UInt64) -> Bool {
        group.members.contains { member in
            guard let identity = registry.terminalIdentity(of: member, in: router.configuration),
                let result = registry.latest(for: identity)
            else { return false }
            return result.networkRevision != revision
        }
    }

    /// 网络修订号变化：去抖后重测活跃的自动组。
    public func networkChanged() {
        eventLoop.execute {
            let revision = self.networkRevision()
            guard revision != self.lastRevision else { return }
            self.lastRevision = revision
            self.debounce?.cancel()
            self.debounce = self.eventLoop.scheduleTask(in: self.settings.networkDebounce) {
                self.tick()
            }
        }
    }

    /// 节点连接失败（被动降级）：进入降级期时重测含它的活跃自动组。
    public func nodeFailed(identity: String) {
        eventLoop.preconditionInEventLoop()
        guard registry.recordFailure(identity) else { return }
        let configuration = router.configuration
        let date = clock()
        for name in configuration.groupOrder {
            guard case .group(let group) = configuration.policies[name], group.type.isAutomatic,
                isActive(name, at: date),
                group.members.contains(where: { registry.terminalIdentity(of: $0, in: configuration) == identity })
            else { continue }
            _ = testGroup(name)
        }
    }

    // MARK: - 测速

    /// 测一个组的全部成员（成员是组时测其当前终点）。
    @discardableResult
    public func testGroup(_ name: String) -> EventLoopFuture<Void> {
        eventLoop.preconditionInEventLoop()
        let configuration = router.configuration
        guard case .group(let group) = configuration.policies[name] else {
            return eventLoop.makeSucceededVoidFuture()
        }
        lastGroupTest[name] = clock()
        let url = group.testURL ?? configuration.general.proxyTestURL
        let timeout = group.timeout ?? configuration.general.testTimeout
        var seen = Set<String>()
        let futures = group.members.compactMap { member -> EventLoopFuture<LatencyResult>? in
            guard let resolution = try? registry.resolveQuietly(member, in: configuration),
                let identity = PolicyRegistry.identity(of: resolution.terminal), seen.insert(identity).inserted
            else { return nil }
            return test(resolution.terminal, url: url, timeout: timeout)
        }
        return EventLoopFuture.whenAllComplete(futures, on: eventLoop).map { _ in }
    }

    /// 测一个节点；同一身份正在测时返回同一个结果。
    func test(_ policy: RuntimePolicy, url: String, timeout: Double) -> EventLoopFuture<LatencyResult> {
        guard let identity = PolicyRegistry.identity(of: policy) else {
            return eventLoop.makeSucceededFuture(failure(.netPolicyUnavailable))
        }
        if let existing = inFlight[identity] {
            return existing
        }
        let connector: (any OutboundConnector)?
        switch policy {
        case .direct: connector = router.direct
        case .proxy(let node): connector = node.connector
        default: connector = nil
        }
        let effectiveURL: String
        let effectiveTimeout: Double
        if case .proxy(let node) = policy {
            effectiveURL = node.testURL ?? url
            effectiveTimeout = node.testTimeout ?? timeout
        } else {
            effectiveURL = url
            effectiveTimeout = timeout
        }
        guard let connector, let target = HTTPProbe.Target(effectiveURL) else {
            let result = failure(.netPolicyUnavailable)
            registry.record(result, for: identity)
            return eventLoop.makeSucceededFuture(result)
        }
        let promise = eventLoop.makePromise(of: LatencyResult.self)
        inFlight[identity] = promise.futureResult
        let run = {
            self.running += 1
            let context = DialContext(
                flowID: FlowID(rawValue: 0), eventLoop: self.eventLoop,
                deadline: .now() + .milliseconds(Int64(effectiveTimeout * 1000)),
                serverResolver: self.router.serverResolver, logger: self.router.dependencies.logger)
            HTTPProbe.measure(
                target, through: connector, context: context,
                timeout: .milliseconds(Int64(effectiveTimeout * 1000)), now: self.now
            ).hop(to: self.eventLoop).whenComplete { outcome in
                self.running -= 1
                let result: LatencyResult
                switch outcome {
                case .success(let milliseconds):
                    result = LatencyResult(
                        latencyMs: milliseconds, errorCode: nil, at: self.clock(),
                        networkRevision: self.networkRevision())
                case .failure(let error):
                    result = self.failure(NetworkErrorMapping.map(error).code)
                }
                self.registry.record(result, for: identity)
                self.inFlight[identity] = nil
                promise.succeed(result)
                self.drain()
            }
        }
        if running < settings.concurrency {
            run()
        } else if queue.count < settings.queueLimit {
            queue.append(run)
        } else {
            inFlight[identity] = nil
            promise.succeed(failure(.netTooManyFlows))
        }
        return promise.futureResult
    }

    private func drain() {
        while running < settings.concurrency, let next = queue.popFirst() {
            next()
        }
    }

    private func failure(_ code: AetherErrorCode) -> LatencyResult {
        LatencyResult(latencyMs: nil, errorCode: code.rawValue, at: clock(), networkRevision: networkRevision())
    }

    // MARK: - 手动测速（IPC）

    /// 开始手动测速：`group` 为组的全部成员，`names` 为指定节点，都为空时测全部节点。名称不存在时抛 `IPC-011`。
    public func startTask(names: [String]?, group: String?) throws -> UInt64 {
        eventLoop.preconditionInEventLoop()
        let configuration = router.configuration
        var targets: [(name: String, policy: RuntimePolicy)] = []
        if let group {
            guard case .group(let policyGroup) = configuration.policies[group] else {
                throw IPCError(code: .ipcInvalidArgument, message: "No policy group named \(group)")
            }
            registry.markUsed(group)
            for member in policyGroup.members {
                guard let resolution = try? registry.resolveQuietly(member, in: configuration),
                    let name = resolution.chain.last, PolicyRegistry.identity(of: resolution.terminal) != nil,
                    !targets.contains(where: { $0.name == name })
                else { continue }
                targets.append((name, resolution.terminal))
            }
        } else if let names, !names.isEmpty {
            for name in names {
                guard let policy = configuration.policies[name], PolicyRegistry.identity(of: policy) != nil else {
                    throw IPCError(code: .ipcInvalidArgument, message: "\(name) is not a node")
                }
                targets.append((name, policy))
            }
        } else {
            targets = configuration.proxyOrder.compactMap { name in configuration.policies[name].map { (name, $0) } }
        }
        let id = nextTaskID
        nextTaskID += 1
        if tasks.count >= Settings.taskLimit, let oldest = tasks.keys.min() {
            tasks[oldest] = nil
        }
        tasks[id] = TaskState(id: id, names: targets.map(\.name))
        let url =
            group.flatMap { name -> String? in
                if case .group(let policyGroup) = configuration.policies[name] { return policyGroup.testURL }
                return nil
            } ?? configuration.general.proxyTestURL
        for target in targets {
            test(target.policy, url: url, timeout: configuration.general.testTimeout).whenSuccess { result in
                self.tasks[id]?.results[target.name] = result
            }
        }
        return id
    }

    public func task(_ id: UInt64) -> TaskState? {
        eventLoop.preconditionInEventLoop()
        return tasks[id]
    }
}
