import AetherFoundation

/// 规则决策缓存（docs/05 §4.3）：LRU，默认容量 4096，满时淘汰最久未使用的条目。
///
/// 只缓存"纯"决策（从头判定、没有解析 DNS、没有遇到依赖 URL / User-Agent 的规则），值只存规则序号，
/// 因此策略组选择变化不影响缓存。缓存与 `RuleProgram` 一一对应，运行配置替换时随旧程序一起丢弃。
/// 不是线程安全的：每个 EventLoop 持有自己的实例。
public final class RuleDecisionCache {
    public static let defaultCapacity = 4096

    struct Key: Hashable {
        var host: String?
        var ip: IPAddress?
        var port: UInt16
        var transport: RouteContext.Transport
        var appProtocol: RouteContext.AppProtocol
        var inboundPort: UInt16?
        var networkRevision: Int
    }

    private var storage: LRUCache<Key, Int>
    public private(set) var hits = 0
    public private(set) var misses = 0

    public init(capacity: Int = RuleDecisionCache.defaultCapacity) {
        storage = LRUCache(capacity: capacity)
    }

    public var count: Int { storage.count }

    /// 内存压力时清空。
    public func removeAll() {
        storage.removeAll()
    }

    static func key(for context: RouteContext) -> Key {
        Key(
            host: context.host?.value, ip: context.destinationIP, port: context.destinationPort,
            transport: context.transport, appProtocol: context.appProtocol, inboundPort: context.inboundPort,
            networkRevision: context.network.revision)
    }

    func lookup(_ key: Key) -> Int? {
        let value = storage.get(key)
        if value == nil { misses += 1 } else { hits += 1 }
        return value
    }

    func store(_ key: Key, index: Int) {
        storage.set(key, index)
    }
}

extension RuleProgram {
    /// 带决策缓存的判定（只用于从头判定；`needsResolution` 之后用 `evaluate(_:from:)` 续算）。
    public func evaluate(_ context: RouteContext, cache: RuleDecisionCache) -> RuleStep {
        guard !context.resolutionFailed else { return evaluate(context) }
        let key = RuleDecisionCache.key(for: context)
        if let index = cache.lookup(key), index < rules.count {
            let rule = rules[index]
            return .decided(
                RuleMatch(
                    policy: rule.policy, rule: RuleReference(index: index, raw: rule.raw, source: rule.source),
                    usedResolution: false))
        }
        let result = evaluateDetailed(context, from: .start)
        if case .decided(let match) = result.step, !match.usedResolution, !result.touchedRequestDetails {
            cache.store(key, index: match.rule.index)
        }
        return result.step
    }
}
