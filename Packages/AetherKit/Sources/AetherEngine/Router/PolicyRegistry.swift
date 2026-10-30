import AetherFoundation
import AetherOutbound
import Foundation

/// 策略解析结果。
public struct PolicyResolution: Sendable {
    /// 规则策略 → … → 最终策略。
    public var chain: [String]
    /// 最终策略（DIRECT、拒绝或节点）。
    public var terminal: RuntimePolicy
}

/// 一次测速的结果（docs/06 §9.2）。
public struct LatencyResult: Sendable, Equatable {
    /// 成功时的延迟（毫秒）。
    public var latencyMs: Int?
    /// 失败时的错误码（`NET-…` / `TLS-…`）。
    public var errorCode: String?
    public var at: Date
    /// 测速时的网络修订号；与当前不同即为过期结果（仍参与选择，直到重测）。
    public var networkRevision: UInt64

    public var succeeded: Bool { latencyMs != nil }

    public init(latencyMs: Int?, errorCode: String?, at: Date, networkRevision: UInt64) {
        self.latencyMs = latencyMs
        self.errorCode = errorCode
        self.at = at
        self.networkRevision = networkRevision
    }
}

/// `evaluate-before-use = true` 的组在没有任何测速结果时抛出：调用方先测速（最多组的 `timeout`）再解析。
public struct PolicyAwaitingEvaluation: Error, Sendable {
    public var group: String
}

/// 策略组运行时状态（docs/06 §9.1）：`select` 的选择、各节点的测速结果与被动失败、自动组的当前成员与最近使用时间。
/// 锁保护，读写都很短。
///
/// - `select`：当前选择；无效（成员已不存在）时回到第一个成员；
/// - `url-test`：延迟最低的可用成员；新最低值比当前成员低于 `tolerance` 才切换，当前成员不可用时立即切到最佳；
/// - `fallback`：按成员顺序第一个可用者；
/// - `load-balance`：可用成员中随机选择，`persistent` 时按主机名做最高随机权重哈希（HRW）；
/// - 自动组没有可用成员时解析到第一个成员；完全没有测速结果时登记为"待测"（`evaluate-before-use = true` 时抛出
///   `PolicyAwaitingEvaluation`）。
/// - "可用" = 最近一次测速成功且不在被动降级期；成员是组时按其当前解析出的终点判断。`DIRECT` 可测速，拒绝类不可用。
/// - 被动失败：同一节点 10 秒内连续 3 次连接失败 → 降级 60 秒（`recordFailure` 返回 true，调用方触发重测）。
/// - 上限：测速结果与失败记录各最多 `identityLimit` 个节点身份，溢出时丢弃最旧的结果；每个节点保留最近 10 次结果；
///   待测组最多 64 个。
/// - 递归解析成员组，深度上限 16（编译期已排除环，这里只做保护）。
public final class PolicyRegistry: Sendable {
    public static let maxDepth = 16
    static let identityLimit = 1024
    static let historyLimit = 10
    static let pendingLimit = 64
    static let failureWindow: TimeInterval = 10
    static let failureThreshold = 3
    static let degradation: TimeInterval = 60

    struct TestState {
        var latest: [String: LatencyResult] = [:]
        var history: [String: [LatencyResult]] = [:]
        var failures: [String: [Date]] = [:]
        var degradedUntil: [String: Date] = [:]
        /// url-test 组的当前成员。
        var autoCurrent: [String: String] = [:]
        /// 自动组最近被流量使用的时间。
        var lastUsed: [String: Date] = [:]
        /// 没有任何测速结果、等待后台测速的组。
        var pending: Set<String> = []
    }

    private let selections: Locked<[String: String]>
    private let tests = Locked(TestState())
    private let clock: @Sendable () -> Date
    private let random: @Sendable (Int) -> Int

    /// - Parameters:
    ///   - selections: 组名 → 选择的成员（来自 `State/selections.json`）。
    ///   - clock: 当前时间（测试注入）。
    ///   - random: `random(n)` 返回 `0..<n` 中的随机数（load-balance，测试注入）。
    public init(
        selections: [String: String] = [:], clock: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable (Int) -> Int = { Int.random(in: 0..<max($0, 1)) }
    ) {
        self.selections = Locked(selections)
        self.clock = clock
        self.random = random
    }

    /// 当前全部选择。
    public var currentSelections: [String: String] {
        selections.current
    }

    /// `select` 组的当前选择（未选择或无效时为第一个成员）。
    public func selection(for group: PolicyGroup) -> String? {
        if let chosen = selections.current[group.name], group.members.contains(chosen) {
            return chosen
        }
        return group.members.first
    }

    /// 设置 `select` 组的选择。成员不存在时抛出 `IPC-011`。
    public func select(_ member: String, in group: PolicyGroup) throws {
        guard group.type == .select else {
            throw NetworkError(.netPolicyUnavailable, "\(group.name) is not a select group")
        }
        guard group.members.contains(member) else {
            throw NetworkError(.netPolicyUnavailable, "\(member) is not a member of \(group.name)")
        }
        selections.withLock { $0[group.name] = member }
    }

    /// 替换全部选择（重载后迁移、启动时载入）。
    public func replaceSelections(_ new: [String: String]) {
        selections.withLock { $0 = new }
    }

    /// 运行配置替换后的迁移（docs/06 §2.4 第 4 步）：同名、仍为 `select` 且成员仍存在的组保留选择，其余丢弃
    /// （之后解析时回到第一个成员）；测速结果按节点身份保留（不再存在的身份丢弃），自动组的当前成员按同名保留。
    public func migrate(to configuration: RuntimeConfiguration) {
        selections.withLock { current in
            current = current.filter { name, member in
                guard case .group(let group) = configuration.policies[name] else { return false }
                return group.type == .select && group.members.contains(member)
            }
        }
        var identities: Set<String> = [Self.directIdentity]
        for case .proxy(let node) in configuration.policies.values {
            identities.insert(node.identity)
        }
        tests.withLock { state in
            state.latest = state.latest.filter { identities.contains($0.key) }
            state.history = state.history.filter { identities.contains($0.key) }
            state.failures = state.failures.filter { identities.contains($0.key) }
            state.degradedUntil = state.degradedUntil.filter { identities.contains($0.key) }
            state.autoCurrent = state.autoCurrent.filter { name, member in
                guard case .group(let group) = configuration.policies[name] else { return false }
                return group.type == .urlTest && group.members.contains(member)
            }
            state.lastUsed = state.lastUsed.filter { configuration.policies[$0.key]?.isGroup == true }
            state.pending = state.pending.filter { configuration.policies[$0]?.isGroup == true }
        }
    }

    // MARK: - 测速结果

    /// DIRECT 的身份（DIRECT 可作为自动组成员测速）。
    public static let directIdentity = "DIRECT"

    /// 策略的身份：节点身份或 `DIRECT`；拒绝类与组没有身份。
    static func identity(of policy: RuntimePolicy) -> String? {
        switch policy {
        case .direct: return directIdentity
        case .proxy(let node): return node.identity
        case .reject, .group: return nil
        }
    }

    public func record(_ result: LatencyResult, for identity: String) {
        tests.withLock { state in
            if state.latest[identity] == nil, state.latest.count >= Self.identityLimit,
                let oldest = state.latest.min(by: { $0.value.at < $1.value.at })?.key
            {
                state.latest[oldest] = nil
                state.history[oldest] = nil
            }
            state.latest[identity] = result
            var history = state.history[identity] ?? []
            history.append(result)
            if history.count > Self.historyLimit {
                history.removeFirst(history.count - Self.historyLimit)
            }
            state.history[identity] = history
            if result.succeeded {
                state.failures[identity] = nil
            }
        }
    }

    public func latest(for identity: String) -> LatencyResult? {
        tests.withLock { $0.latest[identity] }
    }

    /// 最近 10 次结果（旧的在前）。
    public func history(for identity: String) -> [LatencyResult] {
        tests.withLock { $0.history[identity] ?? [] }
    }

    /// 被动失败（docs/06 §9.1）：返回 true 表示该节点刚进入降级期。
    @discardableResult
    public func recordFailure(_ identity: String) -> Bool {
        let now = clock()
        return tests.withLock { state in
            var failures = (state.failures[identity] ?? []).filter { now.timeIntervalSince($0) < Self.failureWindow }
            failures.append(now)
            if failures.count >= Self.failureThreshold {
                state.failures[identity] = nil
                state.degradedUntil[identity] = now.addingTimeInterval(Self.degradation)
                return true
            }
            if state.failures[identity] == nil, state.failures.count >= Self.identityLimit {
                state.failures.removeAll()
            }
            state.failures[identity] = failures
            return false
        }
    }

    /// 连接成功清空被动失败计数。
    public func recordSuccess(_ identity: String) {
        tests.withLock { state in
            if state.failures[identity] != nil {
                state.failures[identity] = nil
            }
        }
    }

    public func isDegraded(_ identity: String) -> Bool {
        let now = clock()
        return tests.withLock { ($0.degradedUntil[identity] ?? .distantPast) > now }
    }

    /// 取出并清空待测组。
    public func takePendingGroups() -> [String] {
        tests.withLock { state in
            defer { state.pending.removeAll() }
            return Array(state.pending)
        }
    }

    /// 自动组最近被使用的时间。
    public func lastUsed(_ group: String) -> Date? {
        tests.withLock { $0.lastUsed[group] }
    }

    /// 标记自动组正在被使用（流量或 App 正在展示）。
    public func markUsed(_ group: String) {
        let now = clock()
        tests.withLock { $0.lastUsed[group] = now }
    }

    // MARK: - 解析

    /// 解析策略名到最终策略。名称不存在或组为空时以 `NET-020` 失败；`host` 用于 `load-balance` 的 `persistent`。
    public func resolve(_ name: String, in configuration: RuntimeConfiguration, host: String? = nil) throws
        -> PolicyResolution
    {
        var chain = [name]
        var current = name
        for _ in 0..<Self.maxDepth {
            guard let policy = configuration.policies[current] else {
                throw NetworkError(.netPolicyUnavailable, "Policy \(current) does not exist")
            }
            guard case .group(let group) = policy else {
                return PolicyResolution(chain: chain, terminal: policy)
            }
            guard let next = try member(of: group, in: configuration, host: host) else {
                throw NetworkError(.netPolicyUnavailable, "Group \(group.name) has no members")
            }
            chain.append(next)
            current = next
        }
        throw NetworkError(.netPolicyUnavailable, "Policy group nesting deeper than \(Self.maxDepth)")
    }

    /// 组当前解析到的成员（不登记使用）。
    public func currentMember(of group: PolicyGroup, in configuration: RuntimeConfiguration, host: String? = nil)
        -> String?
    {
        (try? member(of: group, in: configuration, host: host, markUse: false)) ?? group.members.first
    }

    private func member(
        of group: PolicyGroup, in configuration: RuntimeConfiguration, host: String?, markUse: Bool = true
    ) throws -> String? {
        switch group.type {
        case .select:
            return selection(for: group)
        case .urlTest, .fallback, .loadBalance:
            if markUse { markUsed(group.name) }
            return try automaticMember(of: group, in: configuration, host: host)
        case .subnet:
            return group.members.first
        }
    }

    /// 成员的终点身份（成员是组时按其当前解析）。
    func terminalIdentity(of member: String, in configuration: RuntimeConfiguration) -> String? {
        guard let resolution = try? resolveQuietly(member, in: configuration) else { return nil }
        return Self.identity(of: resolution.terminal)
    }

    /// 不登记使用、不登记待测的解析（用于判断成员可用性与 IPC 展示）。
    func resolveQuietly(_ name: String, in configuration: RuntimeConfiguration) throws -> PolicyResolution {
        var chain = [name]
        var current = name
        for _ in 0..<Self.maxDepth {
            guard let policy = configuration.policies[current] else {
                throw NetworkError(.netPolicyUnavailable, "Policy \(current) does not exist")
            }
            guard case .group(let group) = policy else {
                return PolicyResolution(chain: chain, terminal: policy)
            }
            let next: String?
            switch group.type {
            case .select: next = selection(for: group)
            case .urlTest, .fallback, .loadBalance:
                next =
                    (try? automaticMember(of: group, in: configuration, host: nil, quiet: true)) ?? group.members.first
            case .subnet: next = group.members.first
            }
            guard let next else { throw NetworkError(.netPolicyUnavailable, "Group \(group.name) has no members") }
            chain.append(next)
            current = next
        }
        throw NetworkError(.netPolicyUnavailable, "Policy group nesting deeper than \(Self.maxDepth)")
    }

    private func automaticMember(
        of group: PolicyGroup, in configuration: RuntimeConfiguration, host: String?, quiet: Bool = false
    ) throws -> String? {
        guard let first = group.members.first else { return nil }
        let now = clock()
        // 成员 → (身份, 最近结果)。
        let candidates = group.members.map { member -> (member: String, identity: String?) in
            (member, terminalIdentity(of: member, in: configuration))
        }
        let snapshot = tests.withLock { state in
            candidates.map { candidate -> (member: String, result: LatencyResult?, degraded: Bool) in
                let result = candidate.identity.flatMap { state.latest[$0] }
                let degraded = candidate.identity.map { (state.degradedUntil[$0] ?? .distantPast) > now } ?? false
                return (candidate.member, result, degraded)
            }
        }
        let available = snapshot.filter { $0.result?.succeeded == true && !$0.degraded }
        if snapshot.allSatisfy({ $0.result == nil }), !quiet {
            if group.evaluateBeforeUse {
                throw PolicyAwaitingEvaluation(group: group.name)
            }
            tests.withLock { state in
                if state.pending.count < Self.pendingLimit {
                    state.pending.insert(group.name)
                }
            }
        }
        guard !available.isEmpty else { return first }
        switch group.type {
        case .fallback:
            return available.first?.member
        case .loadBalance:
            if group.persistent, let host {
                return available.max { Self.weight(host, $0.member) < Self.weight(host, $1.member) }?.member
            }
            return available[random(available.count) % available.count].member
        default:
            let best = available.min { ($0.result?.latencyMs ?? .max) < ($1.result?.latencyMs ?? .max) }
            guard let best else { return first }
            let current = tests.withLock { $0.autoCurrent[group.name] }
            var chosen = best.member
            if let current, let entry = available.first(where: { $0.member == current }),
                let currentLatency = entry.result?.latencyMs, let bestLatency = best.result?.latencyMs,
                bestLatency >= currentLatency - group.tolerance
            {
                chosen = current
            }
            if !quiet {
                tests.withLock { $0.autoCurrent[group.name] = chosen }
            }
            return chosen
        }
    }

    /// HRW 权重：FNV-1a(主机名 ‖ 0 ‖ 成员名)。
    static func weight(_ host: String, _ member: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(host.utf8) + [0] + Array(member.utf8) {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return hash
    }
}
