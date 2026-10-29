import AetherFoundation
import Foundation

/// 把配置（与启用的模块）解析、叠加、校验为 `ResolvedProfile`（docs/02 §4、docs/04 §12–§13）。
public enum ProfileResolver {
    /// 解析一份配置文本（不含模块）。
    public static func resolve(profileText: String, fileName: String) -> ResolvedProfile {
        let (document, lexical) = ProfileDocument.parse(profileText, fileName: fileName)
        return resolve(document: document, lexicalDiagnostics: lexical)
    }

    static func resolve(document: ProfileDocument, lexicalDiagnostics: [Diagnostic]) -> ResolvedProfile {
        let fragment = FragmentParser.parse(document, isModule: false)
        var sink = DiagnosticSink(file: document.fileName)
        sink.diagnostics = lexicalDiagnostics + fragment.diagnostics

        var resources = fragment.resources
        let general = GeneralParser.parse(fragment.generalEntries, sink: &sink, resources: &resources)
        let mitm = MITMParser.parse(fragment.mitmEntries, sink: &sink)

        let names = ProfileValidator.checkNames(proxies: fragment.proxies, groups: fragment.groups, sink: &sink)
        ProfileValidator.checkGroups(fragment.groups, names: names, sink: &sink)
        _ = ProfileValidator.checkRulePolicies(fragment.rules, names: names, sink: &sink)
        checkPolicyReferences(general: general, proxies: fragment.proxies, names: names, sink: &sink)
        let rules = ProfileValidator.finalizeRules(fragment.rules, file: document.fileName, sink: &sink)

        return ResolvedProfile(
            general: general,
            proxies: fragment.proxies,
            groups: fragment.groups,
            rules: rules,
            hosts: fragment.hosts,
            urlRewrites: fragment.urlRewrites,
            headerRewrites: fragment.headerRewrites,
            bodyRewrites: fragment.bodyRewrites,
            mapLocals: fragment.mapLocals,
            scripts: fragment.scripts,
            mitm: mitm,
            externalResources: deduplicated(resources),
            diagnostics: sink.diagnostics,
            revision: ""
        )
    }

    /// `[General]` 与节点中引用策略名的参数。
    static func checkPolicyReferences(
        general: GeneralSettings, proxies: [ProxySpec], names: ProfileValidator.PolicyNames, sink: inout DiagnosticSink
    ) {
        if !names.contains(general.resourceFetchPolicy) {
            sink.report(
                .cfgUnknownPolicy, line: nil, arguments: [general.resourceFetchPolicy],
                "resource-fetch-policy references unknown policy \(general.resourceFetchPolicy)")
        }
        for proxy in proxies {
            if let underlying = proxy.underlyingProxy, !names.contains(underlying) {
                sink.report(
                    .cfgUnknownPolicy, line: proxy.source.line, arguments: [proxy.name, underlying],
                    "underlying-proxy of \(proxy.name) references unknown policy \(underlying)")
            }
        }
    }

    /// 按 URL 与用途去重，保留首次出现（含其更新间隔）。
    static func deduplicated(_ resources: [ExternalResourceRef]) -> [ExternalResourceRef] {
        var seen: Set<String> = []
        return resources.filter { seen.insert("\($0.kind.rawValue)|\($0.url)").inserted }
    }
}
