import AetherFoundation

/// 一个文件（配置或模块）类型化后的内容，尚未叠加、尚未做跨条目校验。
public struct ProfileFragment: Sendable {
    public var fileName: String
    public var isModule: Bool
    /// `[General]` 原始键值（叠加时按 04 §12.2 处理 `%APPEND%` / `%INSERT%`）。
    public var generalEntries: [KeyedEntry] = []
    /// `[MITM]` 原始键值。
    public var mitmEntries: [KeyedEntry] = []
    public var proxies: [ProxySpec] = []
    public var groups: [PolicyGroupSpec] = []
    public var rules: [RuleSpec] = []
    public var hosts: [HostSpec] = []
    public var urlRewrites: [URLRewriteSpec] = []
    public var headerRewrites: [HeaderRewriteSpec] = []
    public var bodyRewrites: [BodyRewriteSpec] = []
    public var mapLocals: [MapLocalSpec] = []
    public var scripts: [ScriptSpec] = []
    /// 规则集、域名集、订阅、脚本、Map Local 文件等外部资源（`[General]` 中的数据库在解析 General 时加入）。
    public var resources: [ExternalResourceRef] = []
    public var diagnostics: [Diagnostic] = []

    public init(fileName: String, isModule: Bool) {
        self.fileName = fileName
        self.isModule = isModule
    }
}

/// 把 `ProfileDocument` 类型化为 `ProfileFragment`（docs/04 §4–§11）。
public enum FragmentParser {
    /// 模块允许的节（docs/04 §12.1）。
    public static let moduleSections: Set<ProfileSection> = [
        .general, .rule, .host, .urlRewrite, .headerRewrite, .bodyRewrite, .mapLocal, .script, .mitm,
    ]

    public static func parse(_ document: ProfileDocument, isModule: Bool = false) -> ProfileFragment {
        var fragment = ProfileFragment(fileName: document.fileName, isModule: isModule)
        var sink = DiagnosticSink(file: document.fileName)
        var generalKeyLines: [String: Int] = [:]
        var reportedSections: Set<String> = []

        for line in document.lines {
            switch line.kind {
            case .sectionHeader(let name):
                let normalized = ProfileSection.normalize(name)
                guard !reportedSections.contains(normalized) else { continue }
                if let section = ProfileSection(rawValue: normalized) {
                    if isModule, !moduleSections.contains(section) {
                        reportedSections.insert(normalized)
                        sink.report(
                            .cfgModuleSectionNotAllowed, line: line.lineNumber, arguments: [name],
                            "Modules cannot contain [\(name)]; the section is ignored")
                    }
                } else {
                    reportedSections.insert(normalized)
                    sink.report(
                        .cfgUnknownSection, line: line.lineNumber, arguments: [name],
                        "Unknown section [\(name)]; kept as is")
                }
            case .entry(let entry):
                guard let section = line.section else { continue }
                if isModule, !moduleSections.contains(section) { continue }
                let source = SourceReference(
                    file: document.fileName, line: line.lineNumber, raw: line.raw.trimmingWhitespace())
                parseEntry(
                    entry, in: section, source: source, fragment: &fragment, sink: &sink,
                    generalKeyLines: &generalKeyLines)
            default:
                continue
            }
        }
        fragment.diagnostics = sink.diagnostics
        return fragment
    }

    static func parseEntry(
        _ entry: ProfileEntry, in section: ProfileSection, source: SourceReference, fragment: inout ProfileFragment,
        sink: inout DiagnosticSink, generalKeyLines: inout [String: Int]
    ) {
        let key = entry.key ?? ""
        switch section {
        case .general:
            let lowered = key.lowercased()
            let isOverlay = entry.value.hasPrefix("%APPEND%") || entry.value.hasPrefix("%INSERT%")
            if !isOverlay, let previous = generalKeyLines[lowered] {
                sink.report(
                    .cfgDuplicateGeneralKey, line: source.line, arguments: [key, String(previous)],
                    "[General] \(key) is repeated (first at line \(previous)); the later value wins")
            }
            if !isOverlay { generalKeyLines[lowered] = source.line }
            fragment.generalEntries.append(KeyedEntry(key: lowered, value: entry.value, source: source))
        case .mitm:
            fragment.mitmEntries.append(KeyedEntry(key: key.lowercased(), value: entry.value, source: source))
        case .proxy:
            if let proxy = ProxyParser.parse(name: key, value: entry.value, source: source, sink: &sink) {
                fragment.proxies.append(proxy)
            }
        case .proxyGroup:
            if let group = GroupParser.parse(name: key, value: entry.value, source: source, sink: &sink) {
                fragment.groups.append(group)
                if let path = group.policyPath {
                    fragment.resources.append(
                        ExternalResourceRef(
                            url: path, kind: .policyPath, updateInterval: group.updateInterval, source: source))
                }
            }
        case .rule:
            if let rule = RuleParser.parse(entry.value, mode: .profile, source: source, sink: &sink) {
                fragment.rules.append(rule)
                collectResources(rule, into: &fragment.resources)
            }
        case .host:
            if let host = SectionParsers.host(pattern: key, value: entry.value, source: source, sink: &sink) {
                fragment.hosts.append(host)
            }
        case .urlRewrite:
            if let rewrite = SectionParsers.urlRewrite(entry.value, source: source, sink: &sink) {
                fragment.urlRewrites.append(rewrite)
            }
        case .headerRewrite:
            if let rewrite = SectionParsers.headerRewrite(entry.value, source: source, sink: &sink) {
                fragment.headerRewrites.append(rewrite)
            }
        case .bodyRewrite:
            if let rewrite = SectionParsers.bodyRewrite(entry.value, source: source, sink: &sink) {
                fragment.bodyRewrites.append(rewrite)
            }
        case .mapLocal:
            if let mapLocal = SectionParsers.mapLocal(
                entry.value, source: source, sink: &sink, resources: &fragment.resources)
            {
                fragment.mapLocals.append(mapLocal)
            }
        case .script:
            if let script = SectionParsers.script(
                name: key, value: entry.value, source: source, sink: &sink, resources: &fragment.resources)
            {
                fragment.scripts.append(script)
            }
        }
    }

    /// 规则（含逻辑规则的子规则）引用的远程规则集与域名集。
    static func collectResources(_ rule: RuleSpec, into resources: inout [ExternalResourceRef]) {
        switch rule.condition {
        case .ruleSet(let location) where location != "LAN":
            resources.append(
                ExternalResourceRef(
                    url: location, kind: .ruleSet, updateInterval: rule.options.updateInterval, source: rule.source))
        case .domainSet(let location):
            resources.append(
                ExternalResourceRef(
                    url: location, kind: .domainSet, updateInterval: rule.options.updateInterval, source: rule.source))
        case .and(let children), .or(let children):
            for child in children { collectResources(child, into: &resources) }
        case .not(let child):
            collectResources(child, into: &resources)
        default:
            break
        }
    }
}
