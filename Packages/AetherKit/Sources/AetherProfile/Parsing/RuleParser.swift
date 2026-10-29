import AetherFoundation

/// 规则行的类型化（docs/04 §7、docs/05 §6.1）。配置中的规则带策略；子规则与规则集内规则不带策略。
enum RuleParser {
    /// 识别但在 iOS 上不支持的类型（`CFG-031`）。
    static let unsupportedOnIOS: Set<String> = [
        "PROCESS-NAME", "PROCESS-PATH", "SRC-IP", "SRC-PORT", "SRC-IP-CIDR", "DEVICE-NAME", "MAC-ADDRESS", "IN-TYPE",
        "IN-USER", "IN-NAME", "SRC-GEOIP", "SRC-IP-ASN", "UID",
    ]
    /// 尚未实现的类型（M7），同样解析保留、不生效。
    static let notYetSupported: Set<String> = ["SCRIPT", "CELLULAR-RADIO"]

    static let ipOptionTypes: Set<String> = ["IP-CIDR", "IP-CIDR6", "GEOIP", "IP-ASN", "RULE-SET"]

    enum Mode {
        /// `[Rule]` 节：`类型,值,策略[,选项…]`。
        case profile
        /// 逻辑规则的子规则：`(类型,值[,选项…])`，不带策略。
        case subrule
        /// 规则集文件中的一行：`类型,值[,选项…]`，不带策略。
        case ruleSet
    }

    /// 解析一条规则；失败时报告诊断并返回 nil。
    static func parse(_ text: String, mode: Mode, source: SourceReference, sink: inout DiagnosticSink, depth: Int = 0)
        -> RuleSpec?
    {
        let line = source.line
        guard depth < 16 else {
            sink.report(.cfgSyntax, line: line, "Logical rules are nested too deeply")
            return nil
        }
        let fields: [FieldTokenizer.Field]
        switch FieldTokenizer.split(text) {
        case .success(let value): fields = value
        case .failure(.unterminatedQuote(let offset)):
            sink.report(.cfgSyntax, line: line, column: offset + 1, "Unterminated quote in rule")
            return nil
        case .failure(.unbalancedParentheses(let offset)):
            sink.report(.cfgSyntax, line: line, column: offset + 1, "Unbalanced parentheses in rule")
            return nil
        }
        let type = fields[0].value.uppercased()
        guard !type.isEmpty else {
            sink.report(.cfgSyntax, line: line, "Empty rule")
            return nil
        }

        if type == "FINAL" || type == "MATCH" {
            guard mode == .profile else {
                sink.report(.cfgInvalidRuleOption, line: line, arguments: [type], "FINAL is only allowed in [Rule]")
                return nil
            }
            guard fields.count >= 2, !fields[1].value.isEmpty else {
                sink.report(.cfgMissingParameter, line: line, arguments: ["FINAL"], "FINAL needs a policy")
                return nil
            }
            var options = RuleOptions()
            for option in fields.dropFirst(2) {
                if option.value.lowercased() == "dns-failed" {
                    options.dnsFailed = true
                } else {
                    sink.report(
                        .cfgInvalidRuleOption, line: line, arguments: [option.value],
                        "Unknown FINAL option \(option.value)")
                }
            }
            if type == "MATCH" {
                sink.report(.cfgCompatibilityNote, line: line, arguments: ["MATCH"], "MATCH is treated as FINAL")
            }
            return RuleSpec(condition: .final, policy: fields[1].value, options: options, raw: text, source: source)
        }

        let hasPolicy = mode == .profile
        let minimumFields = hasPolicy ? 3 : 2
        guard fields.count >= minimumFields else {
            sink.report(
                .cfgMissingParameter, line: line, arguments: [type],
                hasPolicy ? "Rule needs a type, a value and a policy" : "Rule needs a type and a value")
            return nil
        }
        let valueField = fields[1]
        let policy = hasPolicy ? fields[2].value : nil
        if let policy, policy.isEmpty {
            sink.report(.cfgMissingParameter, line: line, arguments: [type], "Rule has an empty policy")
            return nil
        }
        let optionFields = fields.dropFirst(hasPolicy ? 3 : 2)

        // 逻辑规则
        if type == "AND" || type == "OR" || type == "NOT" {
            guard let children = parseSubrules(valueField.raw, source: source, sink: &sink, depth: depth) else {
                return nil
            }
            let condition: RuleCondition
            switch type {
            case "AND", "OR":
                guard !children.isEmpty else {
                    sink.report(.cfgSyntax, line: line, arguments: [type], "\(type) needs at least one subrule")
                    return nil
                }
                condition = type == "AND" ? .and(children) : .or(children)
            default:
                guard children.count == 1, let child = children.first else {
                    sink.report(.cfgSyntax, line: line, arguments: [type], "NOT needs exactly one subrule")
                    return nil
                }
                condition = .not(child)
            }
            for option in optionFields {
                sink.report(
                    .cfgInvalidRuleOption, line: line, arguments: [option.value], "Logical rules take no options")
            }
            return RuleSpec(condition: condition, policy: policy, raw: text, source: source)
        }

        let value = valueField.value
        guard let condition = condition(type: type, value: value, mode: mode, source: source, sink: &sink) else {
            return nil
        }
        var options = RuleOptions()
        for option in optionFields {
            let lower = option.value.lowercased()
            if lower == "no-resolve" {
                if ipOptionTypes.contains(type) {
                    options.noResolve = true
                } else {
                    sink.report(
                        .cfgInvalidRuleOption, line: line, arguments: [option.value, type],
                        "no-resolve does not apply to \(type)")
                }
            } else if lower.hasPrefix("update-interval=") {
                guard type == "RULE-SET" || type == "DOMAIN-SET",
                    let seconds = ValueParser.seconds(String(lower.dropFirst("update-interval=".count)))
                else {
                    sink.report(
                        .cfgInvalidRuleOption, line: line, arguments: [option.value, type],
                        "Invalid update-interval for \(type)")
                    continue
                }
                options.updateInterval = seconds
            } else if lower == "extended-matching" {
                sink.report(
                    .cfgCompatibilityNote, line: line, arguments: [option.value],
                    "extended-matching is ignored: sniffed host names are always matched")
            } else if lower == "dns-failed" {
                sink.report(
                    .cfgInvalidRuleOption, line: line, arguments: [option.value, type],
                    "dns-failed only applies to FINAL")
            } else if lower.isEmpty {
                continue
            } else {
                sink.report(
                    .cfgInvalidRuleOption, line: line, arguments: [option.value, type],
                    "Unknown rule option \(option.value)")
            }
        }
        return RuleSpec(condition: condition, policy: policy, options: options, raw: text, source: source)
    }

    /// `((子规则),(子规则)…)`。
    static func parseSubrules(_ raw: String, source: SourceReference, sink: inout DiagnosticSink, depth: Int)
        -> [RuleSpec]?
    {
        let trimmed = raw.trimmingWhitespace()
        guard trimmed.hasPrefix("("), trimmed.hasSuffix(")"), trimmed.unicodeScalars.count >= 2 else {
            sink.report(.cfgSyntax, line: source.line, "Logical rule needs ((subrule),(subrule)…)")
            return nil
        }
        let inner = String(String.UnicodeScalarView(trimmed.unicodeScalars.dropFirst().dropLast()))
        guard case .success(let parts) = FieldTokenizer.split(inner) else {
            sink.report(.cfgSyntax, line: source.line, "Unbalanced subrules")
            return nil
        }
        var children: [RuleSpec] = []
        for part in parts {
            let text = part.raw
            guard text.hasPrefix("("), text.hasSuffix(")"), text.unicodeScalars.count >= 2 else {
                sink.report(
                    .cfgSyntax, line: source.line, arguments: [text], "Subrule \(text) must be wrapped in parentheses")
                return nil
            }
            let body = String(String.UnicodeScalarView(text.unicodeScalars.dropFirst().dropLast()))
            guard let child = parse(body, mode: .subrule, source: source, sink: &sink, depth: depth + 1) else {
                return nil
            }
            children.append(child)
        }
        return children
    }

    static func condition(type: String, value: String, mode: Mode, source: SourceReference, sink: inout DiagnosticSink)
        -> RuleCondition?
    {
        let line = source.line
        func invalid(_ message: String, code: AetherErrorCode = .cfgInvalidValue) -> RuleCondition? {
            sink.report(code, line: line, arguments: [type, value], message)
            return nil
        }
        switch type {
        case "DOMAIN", "DOMAIN-SUFFIX":
            guard let host = Hostname(value) else { return invalid("Invalid domain \(value)") }
            return type == "DOMAIN" ? .domain(host) : .domainSuffix(host)
        case "DOMAIN-KEYWORD":
            guard !value.isEmpty else { return invalid("Empty keyword") }
            return .domainKeyword(value.lowercased())
        case "DOMAIN-WILDCARD":
            guard ValueParser.isValidWildcard(value) else { return invalid("Invalid wildcard \(value)") }
            return .domainWildcard(Hostname(value)?.value ?? value.lowercased())
        case "DOMAIN-SET", "RULE-SET":
            guard mode != .ruleSet else {
                sink.report(
                    .cfgInvalidRuleOption, line: line, arguments: [type], "\(type) is not allowed inside a rule set")
                return nil
            }
            if type == "RULE-SET", value.uppercased() == "LAN" {
                return .ruleSet("LAN")
            }
            switch ValueParser.checkResource(value) {
            case .invalid: return invalid("Invalid \(type) location \(value)", code: .cfgInvalidResourceURL)
            case .insecure:
                sink.report(.cfgInsecureResource, line: line, arguments: [value], "\(type) \(value) uses plain HTTP")
            case .ok: break
            }
            return type == "RULE-SET" ? .ruleSet(value) : .domainSet(value)
        case "IP-CIDR", "IP-CIDR6":
            guard let cidr = CIDR(value), cidr.network.isIPv4 == (type == "IP-CIDR") else {
                return invalid("Invalid \(type) value \(value)", code: .cfgInvalidCIDR)
            }
            return type == "IP-CIDR" ? .ipCIDR(cidr) : .ipCIDR6(cidr)
        case "GEOIP":
            guard value.count == 2, value.allSatisfy({ $0.isASCII && $0.isLetter }) else {
                return invalid("GEOIP needs a two-letter country code")
            }
            return .geoIP(value.uppercased())
        case "IP-ASN":
            let digits = value.uppercased().hasPrefix("AS") ? String(value.dropFirst(2)) : value
            guard let number = UInt32(digits), digits.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                return invalid("IP-ASN needs an AS number")
            }
            return .ipASN(number)
        case "DEST-PORT", "IN-PORT", "DST-PORT":
            guard let range = ValueParser.portRange(value) else {
                return invalid("Invalid port \(value)", code: .cfgInvalidPort)
            }
            if type == "DST-PORT" {
                sink.report(.cfgCompatibilityNote, line: line, arguments: [type], "DST-PORT is treated as DEST-PORT")
            }
            return type == "IN-PORT" ? .inPort(range) : .destPort(range)
        case "PROTOCOL":
            guard let value = RuleProtocol(rawValue: value.uppercased()) else {
                return invalid("PROTOCOL must be TCP, UDP, HTTP, HTTPS or QUIC")
            }
            return .protocol(value)
        case "HOSTNAME-TYPE":
            guard let value = HostnameType(rawValue: value.uppercased()) else {
                return invalid("HOSTNAME-TYPE must be IPv4, IPv6, DOMAIN or SIMPLE")
            }
            return .hostnameType(value)
        case "SUBNET":
            guard let colon = value.firstIndex(of: ":") else { return invalid("SUBNET needs SSID:, BSSID: or TYPE:") }
            let kind = value[..<colon].uppercased()
            let argument = String(value[value.index(after: colon)...])
            switch kind {
            case "SSID" where !argument.isEmpty: return .subnet(.ssid(argument))
            case "BSSID" where !argument.isEmpty: return .subnet(.bssid(argument.lowercased()))
            case "TYPE":
                guard let interface = SubnetCondition.InterfaceType(rawValue: argument.uppercased()) else {
                    return invalid("SUBNET TYPE must be WIFI, CELLULAR or WIRED")
                }
                return .subnet(.interfaceType(interface))
            default: return invalid("SUBNET needs SSID:, BSSID: or TYPE:")
            }
        case "USER-AGENT":
            guard !value.isEmpty else { return invalid("Empty USER-AGENT pattern") }
            return .userAgent(value)
        case "URL-REGEX":
            guard ValueParser.isValidRegex(value) else {
                return invalid("Invalid regular expression \(value)", code: .cfgInvalidRegex)
            }
            return .urlRegex(value)
        case _ where unsupportedOnIOS.contains(type):
            sink.report(
                .cfgRuleUnsupportedOnIOS, line: line, arguments: [type],
                "\(type) is not supported on iOS; the rule never matches")
            return .unsupported(type: type, value: value)
        case _ where notYetSupported.contains(type):
            sink.report(
                .cfgRuleUnsupportedOnIOS, line: line, arguments: [type],
                "\(type) rules arrive in a later version (M7); the rule never matches")
            return .unsupported(type: type, value: value)
        default:
            sink.report(.cfgUnknownRuleType, line: line, arguments: [type], "Unknown rule type \(type)")
            return nil
        }
    }
}
