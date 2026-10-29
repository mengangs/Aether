import AetherFoundation
import Foundation

/// 编译后的正则（`NSRegularExpression` 不可变、线程安全）。
final class CompiledRegex: @unchecked Sendable {
    let regex: NSRegularExpression?

    init(_ pattern: String) {
        regex = try? NSRegularExpression(pattern: pattern)
    }

    /// 在整个字符串上搜索（非整串匹配，docs/05 §3.3）。
    func search(_ text: String) -> Bool {
        guard let regex else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

/// 一条编译后的规则（含子规则）。
struct CompiledRule: Sendable {
    enum Category: Sendable, Equatable {
        case domain
        case ip
        case single
    }

    indirect enum Matcher: Sendable {
        case domain(String)
        case domainSuffix(String)
        case domainKeyword(String)
        case domainWildcard(String)
        case domainSet(ReversedDomainTable?, location: String)
        case ruleSet((any RuleSetMatching)?, location: String)
        case cidr(CIDR)
        case geoIP(String, (any IPMetadataLookup)?)
        case ipASN(UInt32, (any IPMetadataLookup)?)
        case destPort(ClosedRange<UInt16>)
        case inPort(ClosedRange<UInt16>)
        case appProtocol(RuleProtocol)
        case hostnameType(HostnameType)
        case subnet(SubnetCondition)
        case userAgent(String)
        case urlRegex(CompiledRegex)
        case and([CompiledRule])
        case or([CompiledRule])
        case not(CompiledRule)
        case final
        case unavailable(String)
    }

    let index: Int
    let raw: String
    let source: SourceReference
    /// 子规则与规则集内规则为空串。
    let policy: String
    let options: RuleOptions
    let matcher: Matcher

    var category: Category {
        switch matcher {
        case .domain, .domainSuffix, .domainKeyword, .domainWildcard: return .domain
        case .cidr: return .ip
        default: return .single
        }
    }

    /// 是否依赖 URL / User-Agent（含子规则与规则集），影响决策缓存。
    var dependsOnRequestDetails: Bool {
        switch matcher {
        case .userAgent, .urlRegex: return true
        case .and(let children), .or(let children): return children.contains(where: \.dependsOnRequestDetails)
        case .not(let child): return child.dependsOnRequestDetails
        case .ruleSet(let set, _): return set?.dependsOnRequestDetails ?? false
        default: return false
        }
    }

    var traceNote: String? {
        switch matcher {
        case .ruleSet(let set, _): return set.map { "\($0.ruleCount) rules" }
        case .domainSet(let set, _): return set.map { "\($0.count) domains" }
        default: return nil
        }
    }

    func evaluate(_ context: RouteContext) -> RuleOutcome {
        evaluate(context, canResolve: context.host != nil && context.destinationIP == nil && !context.resolutionFailed)
    }

    /// - Parameter canResolve: 上下文只有域名且尚未解析过（是否允许返回 `needsIP`）。
    func evaluate(_ context: RouteContext, canResolve: Bool) -> RuleOutcome {
        let resolvable = canResolve && !options.noResolve
        switch matcher {
        case .domain(let host):
            return outcome(context.host?.value == host)
        case .domainSuffix(let suffix):
            guard let host = context.host?.value else { return .noMatch }
            return outcome(host == suffix || host.hasSuffix("." + suffix))
        case .domainKeyword(let keyword):
            return outcome(context.host?.value.contains(keyword) ?? false)
        case .domainWildcard(let pattern):
            return outcome(context.host.map { Wildcard.matches(pattern, $0.value) } ?? false)
        case .domainSet(let table, _):
            guard let table else { return .undecidable("domain set not loaded") }
            return outcome(context.host.map { table.contains($0.value) } ?? false)
        case .ruleSet(let set, _):
            guard let set else { return .undecidable("rule set not loaded") }
            return set.match(context, noResolve: options.noResolve || !canResolve)
        case .cidr(let cidr):
            guard let ip = context.destinationIP else { return resolvable ? .needsIP : .noMatch }
            return outcome(cidr.contains(ip))
        case .geoIP(let country, let lookup):
            guard let lookup else { return .undecidable("GeoIP database not loaded") }
            guard let ip = context.destinationIP else { return resolvable ? .needsIP : .noMatch }
            guard let found = lookup.country(for: ip) else { return .noMatch }
            return outcome(found.uppercased() == country)
        case .ipASN(let asn, let lookup):
            guard let lookup else { return .undecidable("ASN database not loaded") }
            guard let ip = context.destinationIP else { return resolvable ? .needsIP : .noMatch }
            return outcome(lookup.asn(for: ip) == asn)
        case .destPort(let range):
            return outcome(range.contains(context.destinationPort))
        case .inPort(let range):
            guard let port = context.inboundPort else { return .undecidable("inbound port unknown") }
            return outcome(range.contains(port))
        case .appProtocol(let value):
            switch value {
            case .tcp: return outcome(context.transport == .tcp)
            case .udp: return outcome(context.transport == .udp)
            case .http: return outcome(context.appProtocol == .http)
            case .https: return outcome(context.appProtocol == .https)
            case .quic: return outcome(context.appProtocol == .quic)
            }
        case .hostnameType(let type):
            return outcome(Self.hostnameType(of: context) == type)
        case .subnet(let condition):
            switch condition {
            case .ssid(let ssid):
                guard let current = context.network.ssid else { return .undecidable("SSID unavailable") }
                return outcome(current == ssid)
            case .bssid(let bssid):
                guard let current = context.network.bssid else { return .undecidable("BSSID unavailable") }
                return outcome(current.lowercased() == bssid)
            case .interfaceType(let type):
                guard let current = context.network.interfaceType else { return .undecidable("network type unknown") }
                return outcome(current == type)
            }
        case .userAgent(let pattern):
            guard let agent = context.userAgent else { return .undecidable("User-Agent not visible") }
            return outcome(Wildcard.matches(pattern, agent))
        case .urlRegex(let regex):
            guard let url = context.url else { return .undecidable("URL not visible") }
            return outcome(regex.search(url))
        case .and(let children):
            for child in children {
                switch child.evaluate(context, canResolve: canResolve) {
                case .match: continue
                case .needsIP: return .needsIP
                case .noMatch, .undecidable: return .noMatch
                }
            }
            return .match
        case .or(let children):
            var needsIP = false
            for child in children {
                switch child.evaluate(context, canResolve: canResolve) {
                case .match: return .match
                case .needsIP: needsIP = true
                case .noMatch, .undecidable: continue
                }
            }
            return needsIP ? .needsIP : .noMatch
        case .not(let child):
            switch child.evaluate(context, canResolve: canResolve) {
            case .match: return .noMatch
            case .noMatch: return .match
            case .needsIP: return .needsIP
            case .undecidable(let reason): return .undecidable(reason)
            }
        case .final:
            return .match
        case .unavailable(let reason):
            return .undecidable(reason)
        }
    }

    private func outcome(_ matched: Bool) -> RuleOutcome { matched ? .match : .noMatch }

    /// HOSTNAME-TYPE：主机是 IP 字面量（或只有目标 IP）时为 IPv4 / IPv6；含点的域名为 DOMAIN；否则 SIMPLE。
    static func hostnameType(of context: RouteContext) -> HostnameType? {
        if let host = context.host {
            if let ip = IPAddress(host.value) { return ip.isIPv4 ? .ipv4 : .ipv6 }
            return host.isSimple ? .simple : .domain
        }
        if let ip = context.destinationIP { return ip.unmappedIPv4.isIPv4 ? .ipv4 : .ipv6 }
        return nil
    }
}

/// `RuleSpec` → `CompiledRule`。
struct RuleCompiler {
    let resources: any RuleResourceProvider
    let platform: PlatformCapabilities

    func compile(_ spec: RuleSpec, index: Int) -> CompiledRule {
        CompiledRule(
            index: index, raw: spec.raw, source: spec.source, policy: spec.policy ?? "", options: spec.options,
            matcher: matcher(spec))
    }

    func matcher(_ spec: RuleSpec) -> CompiledRule.Matcher {
        let condition = spec.condition
        if platform.unavailableRuleTypes.contains(condition.typeName) {
            return .unavailable("\(condition.typeName) is unavailable on this platform")
        }
        switch condition {
        case .domain(let host): return .domain(host.value)
        case .domainSuffix(let host): return .domainSuffix(host.value)
        case .domainKeyword(let keyword): return .domainKeyword(keyword)
        case .domainWildcard(let pattern): return .domainWildcard(pattern)
        case .domainSet(let location): return .domainSet(resources.domainSet(location), location: location)
        case .ruleSet(let location):
            return .ruleSet(resources.ruleSet(location) ?? BuiltinRuleSets.named(location), location: location)
        case .ipCIDR(let cidr), .ipCIDR6(let cidr): return .cidr(cidr)
        case .geoIP(let country): return .geoIP(country, resources.geoIP)
        case .ipASN(let asn): return .ipASN(asn, resources.ipASN)
        case .destPort(let range): return .destPort(range)
        case .inPort(let range): return .inPort(range)
        case .protocol(let value): return .appProtocol(value)
        case .hostnameType(let type): return .hostnameType(type)
        case .subnet(let condition): return .subnet(condition)
        case .userAgent(let pattern): return .userAgent(pattern)
        case .urlRegex(let pattern): return .urlRegex(CompiledRegex(pattern))
        case .and(let children): return .and(children.map { compile($0, index: -1) })
        case .or(let children): return .or(children.map { compile($0, index: -1) })
        case .not(let child): return .not(compile(child, index: -1))
        case .final: return .final
        case .unsupported(let type, _): return .unavailable("\(type) is not supported on iOS")
        }
    }
}

/// 编译后的规则集（docs/05 §6.1）：集内规则顺序无意义，域名类合并为一个索引，IP 类合并为区间表。
public struct CompiledRuleSet: RuleSetMatching {
    let domains: DomainIndex
    let ips: IPIndex
    let others: [CompiledRule]
    /// 编译 `others` 用的源规则（写入编译缓存）。
    let otherSpecs: [RuleSpec]
    let hasIPRules: Bool
    /// 是否有不带 no-resolve 的 IP 规则（只有这些规则会为只有域名的流请求解析）。
    let hasResolvableIPRules: Bool
    public let ruleCount: Int
    public let dependsOnRequestDetails: Bool

    init(
        domains: DomainIndex, ips: IPIndex, otherSpecs: [RuleSpec], hasIPRules: Bool, hasResolvableIPRules: Bool,
        ruleCount: Int, resources: some RuleResourceProvider, platform: PlatformCapabilities
    ) {
        let compiler = RuleCompiler(resources: resources, platform: platform)
        self.domains = domains
        self.ips = ips
        self.otherSpecs = otherSpecs
        others = otherSpecs.enumerated().map { compiler.compile($0.element, index: $0.offset) }
        self.hasIPRules = hasIPRules
        self.hasResolvableIPRules = hasResolvableIPRules
        self.ruleCount = ruleCount
        dependsOnRequestDetails = others.contains(where: \.dependsOnRequestDetails)
    }

    /// - Parameter rules: 规则集文件中解析出的规则（不带策略）。不允许的类型（规则集、域名集、FINAL）由解析阶段排除。
    public init(
        _ rules: [RuleSpec], resources: some RuleResourceProvider = EmptyRuleResources(),
        platform: PlatformCapabilities = .iOS
    ) {
        let compiler = RuleCompiler(resources: resources, platform: platform)
        let compiled = rules.enumerated().map { compiler.compile($0.element, index: $0.offset) }
        domains = DomainIndex(compiled.filter { $0.category == .domain }[...])
        let ipRules = compiled.filter { $0.category == .ip }
        ips = IPIndex(ipRules[...])
        hasIPRules = !ipRules.isEmpty
        hasResolvableIPRules = ipRules.contains { !$0.options.noResolve }
        others = compiled.filter { $0.category == .single }
        otherSpecs = zip(rules, compiled).filter { $0.1.category == .single }.map(\.0)
        ruleCount = rules.count
        dependsOnRequestDetails = compiled.contains(where: \.dependsOnRequestDetails)
    }

    public func match(_ context: RouteContext, noResolve: Bool) -> RuleOutcome {
        let canResolve = !noResolve && context.host != nil && context.destinationIP == nil && !context.resolutionFailed
        if let host = context.host, domains.match(host) != nil { return .match }
        var needsIP = false
        if let ip = context.destinationIP {
            if ips.match(ip) != nil { return .match }
        } else if hasResolvableIPRules, canResolve {
            needsIP = true
        }
        for rule in others {
            switch rule.evaluate(context, canResolve: canResolve) {
            case .match: return .match
            case .needsIP: needsIP = true
            case .noMatch, .undecidable: continue
            }
        }
        return needsIP ? .needsIP : .noMatch
    }
}

/// 内置规则集（docs/05 §6.3）。
enum BuiltinRuleSets {
    static func named(_ location: String) -> (any RuleSetMatching)? {
        location.uppercased() == "LAN" ? lan : nil
    }
}
