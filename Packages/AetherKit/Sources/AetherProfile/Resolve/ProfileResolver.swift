import AetherFoundation
import Crypto
import Foundation

/// 把配置与启用的模块解析、叠加、校验为 `ResolvedProfile`（docs/02 §4、docs/04 §12–§13）。
public enum ProfileResolver {
    /// 解析一份配置及启用的模块。
    /// - Parameter modules: 按用户在模块列表中的顺序，排在前面的优先级更高。
    public static func resolve(profileText: String, fileName: String, modules: [ModuleInput] = []) -> ResolvedProfile {
        let (document, lexical) = ProfileDocument.parse(profileText, fileName: fileName)
        let base = FragmentParser.parse(document, isModule: false)
        var sink = DiagnosticSink(file: fileName)
        sink.diagnostics = lexical + base.diagnostics

        let baseNames = ProfileValidator.checkNames(proxies: base.proxies, groups: base.groups, sink: &sink)
        ProfileValidator.checkGroups(base.groups, names: baseNames, sink: &sink)
        _ = ProfileValidator.checkRulePolicies(base.rules, names: baseNames, sink: &sink)

        // 模块：逐个解析；有 error 的模块整体不生效。
        var applied: [ProfileFragment] = []
        var moduleResults: [ResolvedModule] = []
        for module in modules {
            let (fragment, result) = prepare(module, names: baseNames)
            moduleResults.append(result)
            sink.diagnostics += result.diagnostics
            if result.isApplied, let fragment {
                applied.append(fragment)
            }
        }

        // 叠加（04 §12.2）：键值节按优先级从低到高应用；条目类节模块在前、配置在后。
        let generalEntries = KeyedOverlay.apply(
            [base.generalEntries] + applied.reversed().map(\.generalEntries),
            defaultList: GeneralSettings.defaultListText)
        let mitmEntries = KeyedOverlay.apply([base.mitmEntries] + applied.reversed().map(\.mitmEntries)) { _ in nil }
        let ordered = applied + [base]

        var resources = managedProfileResource(document, sink: &sink).map { [$0] } ?? []
        resources += ordered.flatMap(\.resources)
        let general = GeneralParser.parse(generalEntries, sink: &sink, resources: &resources)
        let mitm = MITMParser.parse(mitmEntries, sink: &sink)
        checkPolicyReferences(general: general, proxies: base.proxies, names: baseNames, sink: &sink)
        let rules = ProfileValidator.finalizeRules(ordered.flatMap(\.rules), file: fileName, sink: &sink)
        let scripts = mergeScripts(ordered.flatMap(\.scripts), sink: &sink)

        return ResolvedProfile(
            general: general,
            proxies: base.proxies,
            groups: base.groups,
            rules: rules,
            hosts: ordered.flatMap(\.hosts),
            urlRewrites: ordered.flatMap(\.urlRewrites),
            headerRewrites: ordered.flatMap(\.headerRewrites),
            bodyRewrites: ordered.flatMap(\.bodyRewrites),
            mapLocals: ordered.flatMap(\.mapLocals),
            scripts: scripts,
            mitm: mitm,
            externalResources: deduplicated(resources),
            diagnostics: sink.diagnostics,
            revision: revision(profileText: profileText, fileName: fileName, modules: modules),
            profileFileName: fileName,
            modules: moduleResults
        )
    }

    /// 解析一个模块：元数据、参数替换、类型化、规则策略引用校验。
    static func prepare(_ module: ModuleInput, names: ProfileValidator.PolicyNames) -> (
        ProfileFragment?, ResolvedModule
    ) {
        var sink = DiagnosticSink(file: module.name)
        let (rawDocument, _) = ProfileDocument.parse(module.text, fileName: module.name)
        let metadata = ModuleMetadata.parse(rawDocument, sink: &sink)
        guard
            let substituted = ModuleArgumentSubstitution.substitute(
                module.text, arguments: metadata.arguments, values: module.argumentValues, sink: &sink)
        else {
            return (
                nil,
                ResolvedModule(name: module.name, metadata: metadata, isApplied: false, diagnostics: sink.diagnostics)
            )
        }
        let (document, lexical) = ProfileDocument.parse(substituted, fileName: module.name)
        let fragment = FragmentParser.parse(document, isModule: true)
        sink.diagnostics += lexical + fragment.diagnostics
        _ = ProfileValidator.checkRulePolicies(fragment.rules, names: names, sink: &sink)
        let ok = !sink.diagnostics.containsErrors
        return (
            ok ? fragment : nil,
            ResolvedModule(name: module.name, metadata: metadata, isApplied: ok, diagnostics: sink.diagnostics)
        )
    }

    /// `#!MANAGED-CONFIG <URL> interval=<秒> strict=<bool>`（docs/04 §12.3）：托管配置自身也是外部资源。
    static func managedProfileResource(_ document: ProfileDocument, sink: inout DiagnosticSink) -> ExternalResourceRef?
    {
        guard
            let line = document.lines.first(where: {
                if case .directive(let name, _) = $0.kind { return name.uppercased() == "MANAGED-CONFIG" }
                return false
            }), case .directive(_, let value) = line.kind
        else { return nil }
        let parts = value.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let url = parts.first, url.lowercased().hasPrefix("http") else {
            sink.report(
                .cfgInvalidResourceURL, line: line.lineNumber, arguments: [value], "Invalid #!MANAGED-CONFIG URL")
            return nil
        }
        switch ValueParser.checkResource(url) {
        case .invalid:
            sink.report(.cfgInvalidResourceURL, line: line.lineNumber, arguments: [url], "Invalid #!MANAGED-CONFIG URL")
            return nil
        case .insecure:
            sink.report(
                .cfgInsecureResource, line: line.lineNumber, arguments: [url],
                "Managed profile is downloaded over plain HTTP")
        case .ok:
            break
        }
        var interval: Double?
        for part in parts.dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0].lowercased() {
            case "interval":
                interval = ValueParser.seconds(pair[1])
                if interval == nil {
                    sink.report(
                        .cfgInvalidValue, line: line.lineNumber, arguments: ["interval", pair[1]],
                        "Invalid managed profile interval")
                }
            case "strict":
                if ValueParser.bool(pair[1]) == nil {
                    sink.report(
                        .cfgInvalidValue, line: line.lineNumber, arguments: ["strict", pair[1]],
                        "Invalid managed profile strict flag")
                }
            default:
                sink.report(
                    .cfgUnknownKey, line: line.lineNumber, arguments: [pair[0]],
                    "Unknown #!MANAGED-CONFIG parameter \(pair[0])")
            }
        }
        return ExternalResourceRef(
            url: url, kind: .managedProfile, updateInterval: interval,
            source: SourceReference(file: document.fileName, line: line.lineNumber, raw: line.raw))
    }

    /// 脚本名重复时保留先出现者（`CFG-062`）。
    static func mergeScripts(_ scripts: [ScriptSpec], sink: inout DiagnosticSink) -> [ScriptSpec] {
        var seen: Set<String> = []
        var result: [ScriptSpec] = []
        for script in scripts {
            if seen.insert(script.name).inserted {
                result.append(script)
            } else {
                var local = DiagnosticSink(file: script.source.file)
                local.report(
                    .cfgDuplicateScript, line: script.source.line, arguments: [script.name],
                    "Script \(script.name) is defined more than once; this definition is ignored")
                sink.diagnostics += local.diagnostics
            }
        }
        return result
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

    /// 修订号：配置与全部启用模块的源文本及参数值的 SHA-256（`sha256:<十六进制>`）。参数按名排序，与字典顺序无关。
    public static func revision(profileText: String, fileName: String, modules: [ModuleInput]) -> String {
        var hasher = SHA256()
        func feed(_ text: String) {
            let data = Data(text.utf8)
            var length = UInt64(data.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: data)
        }
        feed("aether-profile-v1")
        feed(fileName)
        feed(profileText)
        for module in modules {
            feed(module.name)
            feed(module.text)
            for key in module.argumentValues.keys.sorted() {
                feed(key)
                feed(module.argumentValues[key] ?? "")
            }
        }
        return "sha256:" + Bytes.hex(hasher.finalize())
    }
}
