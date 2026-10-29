import AetherFoundation

/// 规则集文件的解析（docs/05 §6.1）：每行一条不带策略的规则。
///
/// 不允许的类型（`RULE-SET`、`DOMAIN-SET`、`FINAL`）、iOS 不支持的类型与无效行都跳过并计数，不使整个规则集失败。
/// 超出 32 MiB 或 50 万条时整体拒绝（`RES-010`）；没有任何有效条目时为 `RES-011`。
public enum RuleSetParser {
    public struct Result: Sendable {
        public var rules: [RuleSpec]
        public var statistics: ListLoadStatistics
    }

    public static func parse(
        _ text: String, name: String, maxBytes: Int = ResourceLimits.maxBytes,
        maxEntries: Int = ResourceLimits.maxEntries
    ) -> Swift.Result<Result, ResourceLoadError> {
        let size = text.utf8.count
        guard size <= maxBytes else { return .failure(.tooLarge(bytes: size)) }
        var statistics = ListLoadStatistics()
        var rules: [RuleSpec] = []
        var lineNumber = 0
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            lineNumber += 1
            let line = String(rawLine).trimmingWhitespace()
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            guard rules.count < maxEntries else {
                return .failure(.tooManyEntries(count: rules.count + 1))
            }
            let typeName = line.prefix { $0 != "," }.trimmingWhitespace().uppercased()
            if ["RULE-SET", "DOMAIN-SET", "FINAL", "MATCH"].contains(typeName) {
                statistics.disallowed += 1
                continue
            }
            var sink = DiagnosticSink(file: name)
            let source = SourceReference(file: name, line: lineNumber, raw: line)
            guard let rule = RuleParser.parse(line, mode: .ruleSet, source: source, sink: &sink) else {
                statistics.invalid += 1
                continue
            }
            if !rule.isEffective {
                statistics.unsupported += 1
                continue
            }
            rules.append(rule)
            statistics.accepted += 1
        }
        guard !rules.isEmpty else { return .failure(.noValidEntries) }
        return .success(Result(rules: rules, statistics: statistics))
    }
}
