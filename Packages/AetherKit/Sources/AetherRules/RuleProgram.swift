import AetherFoundation
import Foundation

/// 规则程序中的位置（`needsResolution` 之后从这里继续）。
public struct RuleCursor: Sendable, Equatable, Hashable {
    public let index: Int
    /// 是否是 `needsResolution` 之后的续算位置（命中结果据此标记 `usedResolution`）。
    public let afterResolution: Bool

    public init(index: Int, afterResolution: Bool = false) {
        self.index = index
        self.afterResolution = afterResolution
    }

    public static let start = RuleCursor(index: 0)
}

/// 命中规则的引用：序号、原文与来源（FINAL 也是一条规则）。
public struct RuleReference: Sendable, Equatable {
    /// 0 起的序号；展示时用 `#序号+1`。
    public let index: Int
    public let raw: String
    public let source: SourceReference
}

/// 判定结果。
public struct RuleMatch: Sendable, Equatable {
    /// 策略名（可能是策略组，由引擎继续解析）。
    public let policy: String
    public let rule: RuleReference
    public let usedResolution: Bool
}

/// `evaluate` 的一步。
public enum RuleStep: Sendable, Equatable {
    case decided(RuleMatch)
    /// 需要目标 IP 才能继续：引擎解析后写入 `destinationIP`（或置 `resolutionFailed`），再从 `resume` 继续。
    case needsResolution(Hostname, resume: RuleCursor)
}

/// 编译后的规则程序（docs/05 §1、§4）。不可变；`evaluate` 同步、无副作用，可在 EventLoop 上直接调用。
public struct RuleProgram: Sendable {
    let rules: [CompiledRule]
    let blocks: [Block]
    /// FINAL 的序号（编译时保证存在）。
    let finalIndex: Int

    public var ruleCount: Int { rules.count }

    /// 编译。规则必须已经过 `AetherProfile` 的解析与校验（以 FINAL 结尾，FINAL 之后的规则已移除）；
    /// 缺少 FINAL 时隐式追加 `FINAL,DIRECT`。
    public static func compile(
        _ specs: [RuleSpec], resources: some RuleResourceProvider = EmptyRuleResources(),
        platform: PlatformCapabilities = .iOS
    ) -> RuleProgram {
        var specs = specs
        if let final = specs.firstIndex(where: { $0.condition == .final }) {
            specs = Array(specs[...final])
        } else {
            specs.append(
                RuleSpec(
                    condition: .final, policy: "DIRECT", raw: "FINAL,DIRECT",
                    source: SourceReference(file: "", line: 0, raw: "FINAL,DIRECT")))
        }
        let compiler = RuleCompiler(resources: resources, platform: platform)
        let compiled = specs.enumerated().map { compiler.compile($0.element, index: $0.offset) }
        return RuleProgram(rules: compiled, blocks: Block.make(compiled), finalIndex: compiled.count - 1)
    }

    // MARK: - 判定

    /// 从 `cursor` 开始判定。
    public func evaluate(_ context: RouteContext, from cursor: RuleCursor = .start) -> RuleStep {
        evaluateDetailed(context, from: cursor).step
    }

    struct Detailed {
        var step: RuleStep
        /// 判定过程中是否遇到依赖 URL / User-Agent 的规则（不可缓存）。
        var touchedRequestDetails: Bool
    }

    func evaluateDetailed(_ context: RouteContext, from cursor: RuleCursor) -> Detailed {
        let usedResolution = cursor.afterResolution
        if context.resolutionFailed, rules[finalIndex].options.dnsFailed {
            return Detailed(step: .decided(match(finalIndex, usedResolution: true)), touchedRequestDetails: false)
        }
        var touched = false
        let canResolve = context.host != nil && context.destinationIP == nil && !context.resolutionFailed
        for block in blocks where block.range.upperBound > cursor.index {
            let start = max(block.range.lowerBound, cursor.index)
            switch block.kind {
            case .domain(let index):
                // 域名块不会是续算的起点（续算只发生在需要 IP 的规则上）；从中间开始时退回逐条判定。
                if start == block.range.lowerBound, let host = context.host {
                    if let hit = index.match(host) {
                        return Detailed(
                            step: .decided(match(hit, usedResolution: usedResolution)), touchedRequestDetails: touched)
                    }
                    continue
                }
                if let result = linear(
                    start..<block.range.upperBound, context, canResolve: canResolve, touched: &touched,
                    usedResolution: usedResolution)
                {
                    return Detailed(step: result, touchedRequestDetails: touched)
                }
            case .ip(let index):
                if let ip = context.destinationIP {
                    if start == block.range.lowerBound {
                        if let hit = index.match(ip) {
                            return Detailed(
                                step: .decided(match(hit, usedResolution: usedResolution)),
                                touchedRequestDetails: touched)
                        }
                        continue
                    }
                    if let result = linear(
                        start..<block.range.upperBound, context, canResolve: canResolve, touched: &touched,
                        usedResolution: usedResolution)
                    {
                        return Detailed(step: result, touchedRequestDetails: touched)
                    }
                } else if canResolve, let host = context.host,
                    let first = (start..<block.range.upperBound).first(where: { !rules[$0].options.noResolve })
                {
                    return Detailed(
                        step: .needsResolution(host, resume: RuleCursor(index: first, afterResolution: true)),
                        touchedRequestDetails: touched)
                }
            case .single:
                if let result = linear(
                    start..<block.range.upperBound, context, canResolve: canResolve, touched: &touched,
                    usedResolution: usedResolution)
                {
                    return Detailed(step: result, touchedRequestDetails: touched)
                }
            }
        }
        // FINAL 总是命中，循环中一定已返回；这里只为类型完整。
        return Detailed(
            step: .decided(match(finalIndex, usedResolution: usedResolution)), touchedRequestDetails: touched)
    }

    /// 逐条判定一段规则。
    private func linear(
        _ range: Range<Int>, _ context: RouteContext, canResolve: Bool, touched: inout Bool, usedResolution: Bool
    ) -> RuleStep? {
        for index in range {
            let rule = rules[index]
            if rule.dependsOnRequestDetails { touched = true }
            switch rule.evaluate(context) {
            case .match:
                return .decided(match(index, usedResolution: usedResolution))
            case .needsIP:
                if canResolve, let host = context.host {
                    return .needsResolution(host, resume: RuleCursor(index: index, afterResolution: true))
                }
            case .noMatch, .undecidable:
                continue
            }
        }
        return nil
    }

    private func match(_ index: Int, usedResolution: Bool) -> RuleMatch {
        let rule = rules[index]
        return RuleMatch(
            policy: rule.policy, rule: RuleReference(index: index, raw: rule.raw, source: rule.source),
            usedResolution: usedResolution)
    }

    // MARK: - 追踪

    /// 追踪中的一行。
    public struct TraceEntry: Sendable, Equatable {
        public let index: Int
        public let raw: String
        public let source: SourceReference
        public let outcome: RuleOutcome
        /// 补充说明，如解析结果、规则集条数。
        public let note: String?
    }

    /// 规则测试工具的结果（docs/05 §8.2）。
    public struct RuleTrace: Sendable, Equatable {
        public var entries: [TraceEntry]
        public var match: RuleMatch
        /// 解析：主机名与结果（nil 表示失败）。
        public var resolution: (host: Hostname, addresses: [IPAddress]?)?

        public static func == (lhs: RuleTrace, rhs: RuleTrace) -> Bool {
            lhs.entries == rhs.entries && lhs.match == rhs.match && lhs.resolution?.host == rhs.resolution?.host
                && lhs.resolution?.addresses == rhs.resolution?.addresses
        }
    }

    /// 逐条判定、不使用块索引与缓存；结果必须与 `evaluate` 一致（由测试保证）。
    public func evaluateWithTrace(_ context: RouteContext, resolver: (Hostname) -> [IPAddress]?) -> RuleTrace {
        var context = context
        var entries: [TraceEntry] = []
        var resolution: (Hostname, [IPAddress]?)?
        var index = 0
        while index < rules.count {
            if context.resolutionFailed, rules[finalIndex].options.dnsFailed {
                entries.append(
                    TraceEntry(
                        index: finalIndex, raw: rules[finalIndex].raw, source: rules[finalIndex].source,
                        outcome: .match,
                        note: "dns-failed"))
                return RuleTrace(
                    entries: entries, match: match(finalIndex, usedResolution: true), resolution: resolution)
            }
            let rule = rules[index]
            let outcome = rule.evaluate(context)
            if outcome == .needsIP, let host = context.host, context.destinationIP == nil, !context.resolutionFailed {
                let addresses = resolver(host)
                resolution = (host, addresses)
                if let first = Self.preferredAddress(addresses) {
                    context.destinationIP = first
                } else {
                    context.resolutionFailed = true
                }
                entries.append(
                    TraceEntry(
                        index: index, raw: rule.raw, source: rule.source, outcome: .needsIP,
                        note: addresses.map { "\(host) = \($0.map(\.description).joined(separator: ", "))" }
                            ?? "\(host): resolution failed"))
                continue
            }
            entries.append(
                TraceEntry(index: index, raw: rule.raw, source: rule.source, outcome: outcome, note: rule.traceNote))
            if outcome == .match {
                return RuleTrace(
                    entries: entries, match: match(index, usedResolution: resolution != nil), resolution: resolution)
            }
            index += 1
        }
        return RuleTrace(
            entries: entries, match: match(finalIndex, usedResolution: resolution != nil), resolution: resolution)
    }

    /// 解析结果中优先使用 IPv4（docs/05 §3.2）。
    public static func preferredAddress(_ addresses: [IPAddress]?) -> IPAddress? {
        guard let addresses else { return nil }
        return addresses.first(where: \.isIPv4) ?? addresses.first
    }
}

// MARK: - 块

struct Block: Sendable {
    enum Kind: Sendable {
        case domain(DomainIndex)
        case ip(IPIndex)
        case single
    }

    let range: Range<Int>
    let kind: Kind

    static func make(_ rules: [CompiledRule]) -> [Block] {
        var blocks: [Block] = []
        var start = 0
        while start < rules.count {
            let category = rules[start].category
            var end = start + 1
            if category != .single {
                while end < rules.count, rules[end].category == category {
                    end += 1
                }
            }
            let slice = rules[start..<end]
            switch category {
            case .domain: blocks.append(Block(range: start..<end, kind: .domain(DomainIndex(slice))))
            case .ip: blocks.append(Block(range: start..<end, kind: .ip(IPIndex(slice))))
            case .single: blocks.append(Block(range: start..<end, kind: .single))
            }
            start = end
        }
        return blocks
    }
}

/// 域名块的索引：精确用哈希表，后缀用反转域名表，关键字用线性或 Aho-Corasick，通配线性。
struct DomainIndex: Sendable {
    let exact: [String: Int]
    let suffix: ReversedDomainTable
    let keywords: KeywordMatcher
    let wildcards: [(pattern: String, index: Int)]

    init(_ rules: ArraySlice<CompiledRule>) {
        var exact: [String: Int] = [:]
        var suffix = ReversedDomainTable.Builder()
        var keywords: [(String, Int)] = []
        var wildcards: [(String, Int)] = []
        for rule in rules {
            switch rule.matcher {
            case .domain(let host): exact[host] = min(exact[host] ?? .max, rule.index)
            case .domainSuffix(let host): suffix.add(domain: host, isSuffix: true, value: rule.index)
            case .domainKeyword(let keyword): keywords.append((keyword, rule.index))
            case .domainWildcard(let pattern): wildcards.append((pattern, rule.index))
            default: break
            }
        }
        self.exact = exact
        self.suffix = suffix.build()
        self.keywords = KeywordMatcher(keywords)
        self.wildcards = wildcards
    }

    /// 命中规则中的最小序号。
    func match(_ host: Hostname) -> Int? {
        var best = exact[host.value]
        if let hit = suffix.match(host.value) { best = min(best ?? .max, hit) }
        if let hit = keywords.match(host.value) { best = min(best ?? .max, hit) }
        for (pattern, index) in wildcards where index < (best ?? .max) && Wildcard.matches(pattern, host.value) {
            best = index
            break
        }
        return best
    }
}

/// IP 块的索引：IPv4 与 IPv6 各一张区间表。
struct IPIndex: Sendable {
    let v4: IntervalTable<UInt32>
    let v6: IntervalTable<UInt128Value>

    init(_ rules: ArraySlice<CompiledRule>) {
        var v4: [(UInt32, UInt32, Int)] = []
        var v6: [(UInt128Value, UInt128Value, Int)] = []
        for rule in rules {
            guard case .cidr(let cidr) = rule.matcher else { continue }
            let range = cidr.range
            if let lower = range.lowerBound.ipv4Value, let upper = range.upperBound.ipv4Value {
                v4.append((lower, upper, rule.index))
            } else if let lower = range.lowerBound.ipv6Value, let upper = range.upperBound.ipv6Value {
                v6.append((lower, upper, rule.index))
            }
        }
        self.v4 = IntervalTable(v4.map { (lower: $0.0, upper: $0.1, value: $0.2) })
        self.v6 = IntervalTable(v6.map { (lower: $0.0, upper: $0.1, value: $0.2) })
    }

    func match(_ ip: IPAddress) -> Int? {
        if let value = ip.ipv4Value { return v4.lookup(value) }
        if let value = ip.ipv6Value { return v6.lookup(value) }
        return nil
    }
}
