import AetherFoundation
import AetherProfile
import Testing

@testable import AetherRules

/// 从 `[Rule]` 文本编译规则程序（经过 AetherProfile 的解析）。
func compileRules(_ text: String, resources: some RuleResourceProvider = EmptyRuleResources()) -> RuleProgram {
    let (document, _) = ProfileDocument.parse("[Rule]\n" + text, fileName: "t.conf")
    return RuleProgram.compile(FragmentParser.parse(document).rules, resources: resources)
}

func parseRuleSpecs(_ text: String) -> [RuleSpec] {
    FragmentParser.parse(ProfileDocument.parse("[Rule]\n" + text, fileName: "t.conf").0).rules
}

func context(
    host: String? = nil, ip: String? = nil, port: UInt16 = 443, transport: RouteContext.Transport = .tcp,
    app: RouteContext.AppProtocol = .unknown, url: String? = nil, userAgent: String? = nil, inboundPort: UInt16? = nil,
    network: NetworkSnapshot = NetworkSnapshot()
) -> RouteContext {
    RouteContext(
        host: host.flatMap(Hostname.init), hostSource: host == nil ? .none : .request,
        destinationIP: ip.flatMap(IPAddress.init),
        destinationPort: port, transport: transport, appProtocol: app, inboundPort: inboundPort, url: url,
        userAgent: userAgent,
        network: network)
}

/// 按引擎的方式判定：遇到 needsResolution 时调用 resolver，再从续算位置继续。
func decide(_ program: RuleProgram, _ start: RouteContext, resolver: (Hostname) -> [IPAddress]? = { _ in nil })
    -> RuleMatch
{
    var ctx = start
    var cursor = RuleCursor.start
    for _ in 0..<4 {
        switch program.evaluate(ctx, from: cursor) {
        case .decided(let match):
            return match
        case .needsResolution(let host, let resume):
            if let ip = RuleProgram.preferredAddress(resolver(host)) {
                ctx.destinationIP = ip
            } else {
                ctx.resolutionFailed = true
            }
            cursor = resume
        }
    }
    Issue.record("resolution requested more than once")
    return RuleMatch(
        policy: "?", rule: RuleReference(index: -1, raw: "", source: SourceReference(file: "", line: 0, raw: "")),
        usedResolution: true)
}

/// 测试用的 GeoIP / ASN 表。
struct FakeLookup: IPMetadataLookup {
    var countries: [String: String] = [:]
    var asns: [String: UInt32] = [:]

    func country(for address: IPAddress) -> String? { countries[address.description] }
    func asn(for address: IPAddress) -> UInt32? { asns[address.description] }
}

struct FakeResources: RuleResourceProvider {
    var ruleSets: [String: CompiledRuleSet] = [:]
    var domainSets: [String: ReversedDomainTable] = [:]
    var geoIP: (any IPMetadataLookup)?
    var ipASN: (any IPMetadataLookup)?

    func ruleSet(_ location: String) -> (any RuleSetMatching)? { ruleSets[location] }
    func domainSet(_ location: String) -> ReversedDomainTable? { domainSets[location] }
}
