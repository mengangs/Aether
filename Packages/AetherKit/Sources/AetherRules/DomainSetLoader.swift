import AetherFoundation

/// 域名集的解析（docs/05 §6.2）：每行一个域名；`.example.com` 匹配自身及全部子域名，`example.com` 只匹配自身。
/// `#` 开头为注释，空行忽略，无效行跳过并计数。超出 32 MiB 或 50 万条时整体拒绝（`RES-010`），
/// 没有有效条目时为 `RES-011`。
public enum DomainSetLoader {
    public struct Result: Sendable {
        public var table: ReversedDomainTable
        public var statistics: ListLoadStatistics
    }

    public static func load(
        _ text: String, maxBytes: Int = ResourceLimits.maxBytes, maxEntries: Int = ResourceLimits.maxEntries
    ) -> Swift.Result<Result, ResourceLoadError> {
        let size = text.utf8.count
        guard size <= maxBytes else { return .failure(.tooLarge(bytes: size)) }
        var statistics = ListLoadStatistics()
        var builder = ReversedDomainTable.Builder()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            var line = Substring(rawLine)
            while let first = line.first, first == " " || first == "\t" { line = line.dropFirst() }
            while let last = line.last, last == " " || last == "\t" || last == "\r" { line = line.dropLast() }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            guard statistics.accepted < maxEntries else {
                return .failure(.tooManyEntries(count: statistics.accepted + 1))
            }
            let isSuffix = line.hasPrefix(".")
            let body = isSuffix ? line.dropFirst() : line
            // 兼容 `+.example.com` 写法（视为后缀）。
            let normalized = body.hasPrefix("+.") ? body.dropFirst(2) : body
            guard let host = Hostname(normalized), !host.isIPAddress || !isSuffix else {
                statistics.invalid += 1
                continue
            }
            builder.add(domain: host.value, isSuffix: isSuffix || body.hasPrefix("+."), value: 0)
            statistics.accepted += 1
        }
        guard statistics.accepted > 0 else { return .failure(.noValidEntries) }
        return .success(Result(table: builder.build(), statistics: statistics))
    }
}

extension BuiltinRuleSets {
    /// 内置规则集 `LAN`（docs/05 §6.3）。
    ///
    /// 其中的 IP 规则按 no-resolve 处理：`RULE-SET,LAN,DIRECT` 通常是第一条规则，若为它解析，每个只有域名的流都要先发起
    /// 一次 DNS 查询，Fake IP 模式失去意义。局域网目标经 `DOMAIN-SUFFIX,local`、`HOSTNAME-TYPE,SIMPLE` 命中，
    /// 或因 `always-real-ip` 返回真实地址而带着 IP 到达。
    static let lan: CompiledRuleSet = {
        let source = SourceReference(file: "LAN", line: 0, raw: "")
        func rule(_ condition: RuleCondition, _ raw: String) -> RuleSpec {
            RuleSpec(condition: condition, policy: nil, options: RuleOptions(noResolve: true), raw: raw, source: source)
        }
        var rules: [RuleSpec] = []
        for text in [
            "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12", "192.168.0.0/16",
            "224.0.0.0/4", "255.255.255.255/32",
        ] {
            if let cidr = CIDR(text) { rules.append(rule(.ipCIDR(cidr), "IP-CIDR,\(text)")) }
        }
        for text in ["::1/128", "fc00::/7", "fe80::/10", "ff00::/8"] {
            if let cidr = CIDR(text) { rules.append(rule(.ipCIDR6(cidr), "IP-CIDR6,\(text)")) }
        }
        if let local = Hostname("local") { rules.append(rule(.domainSuffix(local), "DOMAIN-SUFFIX,local")) }
        rules.append(rule(.hostnameType(.simple), "HOSTNAME-TYPE,SIMPLE"))
        return CompiledRuleSet(rules)
    }()
}
