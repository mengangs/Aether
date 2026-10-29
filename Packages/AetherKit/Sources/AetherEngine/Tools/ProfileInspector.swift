import AetherFoundation
import AetherProfile
import AetherRules
import Foundation

/// 开发调试工具的核心（`aether-cli` 与规则测试工具共用，docs/05 §8.2）。输出为稳定的文本，便于黄金文件测试。
public enum ProfileInspector {
    /// 一个源文件。
    public struct Source: Sendable {
        public var name: String
        public var text: String

        public init(name: String, text: String) {
            self.name = name
            self.text = text
        }
    }

    // MARK: check

    /// 校验配置并列出诊断。退出码：有 error 为 1，否则 0。
    public static func check(_ profile: Source, modules: [Source] = []) -> (output: String, exitCode: Int32) {
        let resolved = resolve(profile, modules: modules)
        var lines: [String] = []
        lines.append(
            "\(profile.name): \(resolved.proxies.count) proxies, \(resolved.groups.count) groups, \(resolved.rules.count) rules, "
                + "\(resolved.hosts.count) hosts, \(resolved.scripts.count) scripts, \(resolved.externalResources.count) external resources"
        )
        for module in resolved.modules {
            lines.append(
                "module \(module.name): \(module.metadata.name ?? "-") (\(module.isApplied ? "applied" : "not applied"))"
            )
        }
        // 按文件（配置在前）与行号排序，便于阅读；与整份文件相关（无行号）的诊断排在该文件最后。
        let ordered = resolved.diagnostics.enumerated().sorted { lhs, rhs in
            let l = lhs.element
            let r = rhs.element
            if l.file != r.file { return l.file == profile.name || (r.file != profile.name && l.file < r.file) }
            if l.line != r.line { return (l.line ?? .max) < (r.line ?? .max) }
            return lhs.offset < rhs.offset
        }
        for (_, diagnostic) in ordered {
            lines.append(diagnostic.description)
        }
        let counts = Dictionary(grouping: resolved.diagnostics, by: \.severity).mapValues(\.count)
        lines.append(
            "summary: \(counts[.error] ?? 0) errors, \(counts[.warning] ?? 0) warnings, \(counts[.info] ?? 0) infos; "
                + (resolved.isCommittable ? "committable" : "not committable"))
        lines.append("revision: \(resolved.revision)")
        return (lines.joined(separator: "\n") + "\n", resolved.isCommittable ? 0 : 1)
    }

    // MARK: render

    public static func render(_ profile: Source, redact: Bool) -> String {
        ProfileDocument.parse(profile.text, fileName: profile.name).0.render(redactingSecrets: redact)
    }

    // MARK: match

    /// 规则测试的输入。
    public struct MatchQuery: Sendable {
        /// 主机名、IP 字面量或完整 URL。
        public var target: String
        public var port: UInt16?
        public var transport: RouteContext.Transport = .tcp
        public var appProtocol: RouteContext.AppProtocol?
        public var userAgent: String?
        public var inboundPort: UInt16?
        public var network = NetworkSnapshot()
        /// 离线解析表：主机名 → 地址。没有的主机名视为解析失败。
        public var resolutions: [String: [IPAddress]] = [:]
        /// `select` 组的选择（组名 → 成员），未给出时取第一个成员。
        public var selections: [String: String] = [:]

        public init(target: String) {
            self.target = target
        }
    }

    /// 逐条追踪匹配过程并给出策略链。`resources` 为外部资源位置 → 内容（规则集、域名集）。
    public static func match(
        _ profile: Source, modules: [Source] = [], query: MatchQuery, resources: [String: String] = [:]
    )
        -> String
    {
        let resolved = resolve(profile, modules: modules)
        var notes: [String] = []
        let provider = InspectorResources(resolved: resolved, contents: resources, notes: &notes)
        let program = RuleProgram.compile(resolved.rules, resources: provider)
        let context = makeContext(query)
        let trace = program.evaluateWithTrace(context) { host in query.resolutions[host.value] }

        var lines = notes
        lines.append("target: \(describe(context))")
        let width = min(max(trace.entries.map { "#\($0.index + 1) \($0.raw)".count }.max() ?? 0, 20), 72)
        for entry in trace.entries {
            let head = "#\(entry.index + 1) \(entry.raw)"
            let padded = head.count >= width ? head + " " : head + String(repeating: " ", count: width - head.count + 1)
            var outcome: String
            switch entry.outcome {
            case .match: outcome = "命中"
            case .noMatch: outcome = "不命中"
            case .needsIP: outcome = "需要 IP → 解析"
            case .undecidable(let reason): outcome = "不可判定（\(reason)）"
            }
            if let note = entry.note { outcome += "（\(note)）" }
            lines.append(padded + outcome)
        }
        lines.append("命中：#\(trace.match.rule.index + 1) \(trace.match.rule.raw)（\(location(trace.match.rule.source))）")
        lines.append(
            "策略链："
                + policyChain(trace.match.policy, resolved: resolved, selections: query.selections).joined(
                    separator: " → "))
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: 内部

    public static func resolve(_ profile: Source, modules: [Source]) -> ResolvedProfile {
        ProfileResolver.resolve(
            profileText: profile.text, fileName: profile.name,
            modules: modules.map { ModuleInput(name: $0.name, text: $0.text) })
    }

    static func location(_ source: SourceReference) -> String {
        source.line == 0 ? "\(source.file.isEmpty ? "implicit" : source.file)" : "\(source.file):\(source.line)"
    }

    static func makeContext(_ query: MatchQuery) -> RouteContext {
        var target = query.target
        var url: String?
        var port = query.port
        var appProtocol = query.appProtocol ?? .unknown
        if let components = URLComponents(string: target), let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = components.host
        {
            url = target
            target = host
            port = port ?? UInt16(components.port ?? (scheme == "https" ? 443 : 80))
            if query.appProtocol == nil { appProtocol = scheme == "https" ? .https : .http }
        }
        let address = IPAddress(target.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        return RouteContext(
            host: address == nil ? Hostname(target) : nil, hostSource: address == nil ? .request : .none,
            destinationIP: address,
            destinationPort: port ?? 443, transport: query.transport, appProtocol: appProtocol, inbound: .httpProxy,
            inboundPort: query.inboundPort, url: url, userAgent: query.userAgent, network: query.network)
    }

    static func describe(_ context: RouteContext) -> String {
        var parts: [String] = []
        if let host = context.host { parts.append("host=\(host)") }
        if let ip = context.destinationIP { parts.append("ip=\(ip)") }
        parts.append("port=\(context.destinationPort)")
        parts.append(context.transport.rawValue)
        if context.appProtocol != .unknown { parts.append(context.appProtocol.rawValue) }
        if context.url != nil { parts.append("url") }
        return parts.joined(separator: " ")
    }

    /// 策略链：沿 `select` 组的选择（默认第一个成员）展开；自动组离线无法确定，标为"自动"。深度上限 16。
    static func policyChain(_ start: String, resolved: ResolvedProfile, selections: [String: String]) -> [String] {
        var chain = [start]
        var current = start
        for _ in 0..<16 {
            guard let group = resolved.groups.first(where: { $0.name == current }) else { break }
            if group.type == .select {
                guard let next = selections[group.name] ?? group.members.first else {
                    chain.append("（成员来自订阅，未加载）")
                    break
                }
                chain.append(next)
                current = next
            } else {
                chain.append("（\(group.type.rawValue) 自动选择）")
                break
            }
        }
        return chain
    }
}

/// 从给定内容编译规则集与域名集；缺失的远程资源记为未加载。
struct InspectorResources: RuleResourceProvider {
    var ruleSets: [String: CompiledRuleSet] = [:]
    var domainSets: [String: ReversedDomainTable] = [:]
    var geoIP: (any IPMetadataLookup)? { nil }
    var ipASN: (any IPMetadataLookup)? { nil }

    init(resolved: ResolvedProfile, contents: [String: String], notes: inout [String]) {
        for resource in resolved.externalResources {
            guard resource.kind == .ruleSet || resource.kind == .domainSet else { continue }
            guard let text = contents[resource.url] else {
                notes.append(
                    "note: \(resource.kind.rawValue) \(resource.url) is not loaded; rules using it are undecidable")
                continue
            }
            if resource.kind == .ruleSet {
                switch RuleSetParser.parse(text, name: resource.url) {
                case .success(let result):
                    ruleSets[resource.url] = CompiledRuleSet(result.rules)
                    notes.append(
                        "note: rule-set \(resource.url): \(result.statistics.accepted) rules, \(result.statistics.skipped) skipped"
                    )
                case .failure(let error):
                    notes.append("note: rule-set \(resource.url): \(error.code) \(error.debugDetails)")
                }
            } else {
                switch DomainSetLoader.load(text) {
                case .success(let result):
                    domainSets[resource.url] = result.table
                    notes.append(
                        "note: domain-set \(resource.url): \(result.statistics.accepted) domains, \(result.statistics.skipped) skipped"
                    )
                case .failure(let error):
                    notes.append("note: domain-set \(resource.url): \(error.code) \(error.debugDetails)")
                }
            }
        }
    }

    func ruleSet(_ location: String) -> (any RuleSetMatching)? { ruleSets[location] }
    func domainSet(_ location: String) -> ReversedDomainTable? { domainSets[location] }
}
