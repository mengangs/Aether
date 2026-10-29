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
    /// 全部顶层域名类规则的统一索引：一次查找得到命中的最小序号。
    let domainIndex: DomainIndex
    /// 非域名类规则的块（IP 块与单条），按序号顺序。
    let blocks: [Block]
    /// 热路径用的平行数组（只含平凡类型，遍历时没有引用计数开销）：块的序号范围、块是否为 IP 块。
    let blockRanges: [Range<Int>]
    let blockIsIP: [Bool]
    /// 每条规则是否为可请求解析的 IP 规则（IP 类且不带 no-resolve）、是否为域名类、是否依赖 URL / User-Agent。
    let resolvableIP: [Bool]
    let isDomain: [Bool]
    let dependsOnDetails: [Bool]
    /// FINAL 的序号（编译时保证存在）。
    let finalIndex: Int

    init(rules: [CompiledRule], domainIndex: DomainIndex, blocks: [Block], finalIndex: Int) {
        self.rules = rules
        self.domainIndex = domainIndex
        self.blocks = blocks
        self.finalIndex = finalIndex
        blockRanges = blocks.map(\.range)
        blockIsIP = blocks.map {
            if case .ip = $0.kind { return true }
            return false
        }
        resolvableIP = rules.map { $0.category == .ip && !$0.options.noResolve }
        isDomain = rules.map { $0.category == .domain }
        dependsOnDetails = rules.map(\.dependsOnRequestDetails)
    }

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
        return RuleProgram(
            rules: compiled, domainIndex: DomainIndex(compiled.filter { $0.category == .domain }[...]),
            blocks: Block.make(compiled), finalIndex: compiled.count - 1)
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
        // 域名类规则：统一索引给出命中的最小序号 D。只需按顺序判定 D 之前的非域名类规则。
        // 续算位置总在需要 IP 的规则上，此前已确认 D 在它之后，因此 D ≥ cursor。
        var domainHit = Int.max
        if let host = context.host, let hit = domainIndex.match(host), hit >= cursor.index {
            domainHit = hit
        }
        for blockIndex in blockRanges.indices {
            let range = blockRanges[blockIndex]
            if range.upperBound <= cursor.index { continue }
            if range.lowerBound >= domainHit { break }
            let start = max(range.lowerBound, cursor.index)
            let end = min(range.upperBound, domainHit)
            if blockIsIP[blockIndex] {
                if let ip = context.destinationIP {
                    if start == range.lowerBound, case .ip(let index) = blocks[blockIndex].kind {
                        if let hit = index.match(ip), hit < domainHit {
                            return Detailed(
                                step: .decided(match(hit, usedResolution: usedResolution)),
                                touchedRequestDetails: touched)
                        }
                        continue
                    }
                    if let result = linear(
                        start..<end, context, canResolve: canResolve, touched: &touched, usedResolution: usedResolution)
                    {
                        return Detailed(step: result, touchedRequestDetails: touched)
                    }
                } else if canResolve, let host = context.host {
                    var first = start
                    while first < end, !resolvableIP[first] { first += 1 }
                    if first < end {
                        return Detailed(
                            step: .needsResolution(host, resume: RuleCursor(index: first, afterResolution: true)),
                            touchedRequestDetails: touched)
                    }
                }
            } else if let result = linear(
                start..<end, context, canResolve: canResolve, touched: &touched, usedResolution: usedResolution)
            {
                return Detailed(step: result, touchedRequestDetails: touched)
            }
        }
        if domainHit != Int.max {
            return Detailed(
                step: .decided(match(domainHit, usedResolution: usedResolution)), touchedRequestDetails: touched)
        }
        // FINAL 是单条规则，总会在循环中命中；这里只为类型完整。
        return Detailed(
            step: .decided(match(finalIndex, usedResolution: usedResolution)), touchedRequestDetails: touched)
    }

    /// 逐条判定一段规则。
    private func linear(
        _ range: Range<Int>, _ context: RouteContext, canResolve: Bool, touched: inout Bool, usedResolution: Bool
    ) -> RuleStep? {
        // 通过缓冲区借用元素，避免逐条复制 CompiledRule（其中有多个引用计数字段）。
        var found: (index: Int, outcome: RuleOutcome)?
        rules.withUnsafeBufferPointer { buffer in
            for index in range where !isDomain[index] {
                if dependsOnDetails[index] { touched = true }
                let outcome = buffer[index].evaluate(context, canResolve: canResolve)
                switch outcome {
                case .match, .needsIP:
                    found = (index, outcome)
                    return
                case .noMatch, .undecidable:
                    continue
                }
            }
        }
        guard let found else { return nil }
        if found.outcome == .needsIP {
            guard canResolve, let host = context.host else { return nil }
            return .needsResolution(host, resume: RuleCursor(index: found.index, afterResolution: true))
        }
        return .decided(match(found.index, usedResolution: usedResolution))
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
        case domain
        case ip(IPIndex)
        case single
    }

    let range: Range<Int>
    let kind: Kind

    /// 在去掉域名类规则后的序列上，把连续的同类规则合并为块（域名类规则由程序级索引处理，不打断块）。
    /// 块的范围是原序号范围，其中可能夹有域名类规则；判定时跳过它们。
    static func make(_ rules: [CompiledRule]) -> [Block] {
        var blocks: [Block] = []
        var current: [Int] = []
        var category: CompiledRule.Category?
        func flush() {
            guard let first = current.first, let last = current.last, let category else { return }
            let members = current.map { rules[$0] }
            switch category {
            case .ip: blocks.append(Block(range: first..<(last + 1), kind: .ip(IPIndex(members[...]))))
            default: blocks.append(Block(range: first..<(last + 1), kind: .single))
            }
            current = []
        }
        for rule in rules where rule.category != .domain {
            if rule.category != category {
                flush()
                category = rule.category
            }
            current.append(rule.index)
        }
        flush()
        return blocks
    }
}

/// 域名类规则的索引：精确用哈希表，后缀用反转域名表，关键字用线性或 Aho-Corasick，通配线性。
/// 规则程序对全部顶层域名规则建一个索引；规则集各建一个。
struct DomainIndex: Sendable {
    let exact: [String: Int]
    let suffix: ReversedDomainTable
    let keywords: KeywordMatcher
    let wildcards: [(pattern: String, index: Int)]
    private let compiledWildcards: [(pattern: CompiledWildcard, index: Int)]

    init(
        exact: [String: Int], suffix: ReversedDomainTable, keywords: KeywordMatcher,
        wildcards: [(pattern: String, index: Int)]
    ) {
        self.exact = exact
        self.suffix = suffix
        self.keywords = keywords
        self.wildcards = wildcards
        compiledWildcards = wildcards.map { (CompiledWildcard($0.pattern), $0.index) }
    }

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
        compiledWildcards = wildcards.map { (CompiledWildcard($0.0), $0.1) }
    }

    /// 命中规则中的最小序号。
    func match(_ host: Hostname) -> Int? {
        var best = exact[host.value]
        if let hit = suffix.match(host.value) { best = min(best ?? .max, hit) }
        if let hit = keywords.match(host.value) { best = min(best ?? .max, hit) }
        if !compiledWildcards.isEmpty {
            let bytes = Array(host.value.utf8)
            for (pattern, index) in compiledWildcards {
                if index >= (best ?? .max) { break }
                if pattern.matches(bytes) {
                    best = index
                    break
                }
            }
        }
        return best
    }
}

/// IP 块的索引：IPv4 与 IPv6 各一张区间表。
struct IPIndex: Sendable {
    let v4: IntervalTable<UInt32>
    let v6: IntervalTable<UInt128Value>

    init(v4: IntervalTable<UInt32>, v6: IntervalTable<UInt128Value>) {
        self.v4 = v4
        self.v6 = v6
    }

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
