import AetherFoundation
import AetherOutbound

/// 策略解析结果。
public struct PolicyResolution: Sendable {
    /// 规则策略 → … → 最终策略。
    public var chain: [String]
    /// 最终策略（DIRECT、拒绝或节点）。
    public var terminal: RuntimePolicy
}

/// 策略组运行时状态（docs/06 §9.1）：当前选择。绑定到数据面 EventLoop 之外的锁保护，读写都很短。
///
/// - `select`：当前选择；无效（成员已不存在）时回到第一个成员；
/// - `url-test` / `fallback` / `load-balance`：M3-07 之前解析到第一个成员；
/// - 递归解析成员组，深度上限 16（编译期已排除环，这里只做保护）。
public final class PolicyRegistry: Sendable {
    public static let maxDepth = 16

    private let selections: Locked<[String: String]>

    /// - Parameter selections: 组名 → 选择的成员（来自 `State/selections.json`）。
    public init(selections: [String: String] = [:]) {
        self.selections = Locked(selections)
    }

    /// 当前全部选择。
    public var currentSelections: [String: String] {
        selections.current
    }

    /// 组的当前选择（未选择或无效时为第一个成员）。
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
    /// （之后解析时回到第一个成员）。
    public func migrate(to configuration: RuntimeConfiguration) {
        selections.withLock { current in
            current = current.filter { name, member in
                guard case .group(let group) = configuration.policies[name] else { return false }
                return group.type == .select && group.members.contains(member)
            }
        }
    }

    /// 解析策略名到最终策略。名称不存在或组为空时以 `NET-020` 失败。
    public func resolve(_ name: String, in configuration: RuntimeConfiguration) throws -> PolicyResolution {
        var chain = [name]
        var current = name
        for _ in 0..<Self.maxDepth {
            guard let policy = configuration.policies[current] else {
                throw NetworkError(.netPolicyUnavailable, "Policy \(current) does not exist")
            }
            guard case .group(let group) = policy else {
                return PolicyResolution(chain: chain, terminal: policy)
            }
            guard let next = selection(for: group) else {
                throw NetworkError(.netPolicyUnavailable, "Group \(group.name) has no members")
            }
            chain.append(next)
            current = next
        }
        throw NetworkError(.netPolicyUnavailable, "Policy group nesting deeper than \(Self.maxDepth)")
    }
}
