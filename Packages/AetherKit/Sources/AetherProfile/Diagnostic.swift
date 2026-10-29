import AetherFoundation

/// 配置诊断（docs/04 §13）。每条包含码、级别、文件、行号、可选列号与本地化插值参数。
public struct Diagnostic: Sendable, Hashable, Codable, CustomStringConvertible {
    public enum Severity: String, Sendable, Codable, Comparable, CaseIterable {
        case info
        case warning
        case error

        private var rank: Int {
            switch self {
            case .info: return 0
            case .warning: return 1
            case .error: return 2
            }
        }

        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public var code: AetherErrorCode
    public var severity: Severity
    /// 配置或模块名。
    public var file: String
    /// 行号（1 起）；与整份文件相关时为 nil。
    public var line: Int?
    public var column: Int?
    /// 本地化消息插值参数（如未知的键名、无效的值）。
    public var arguments: [String]
    /// 英文调试说明；界面文案由 App 按 `code` 本地化。
    public var message: String

    public init(
        _ code: AetherErrorCode, file: String, line: Int? = nil, column: Int? = nil, arguments: [String] = [],
        message: String
    ) {
        self.code = code
        self.severity = DiagnosticCatalog.severity(of: code)
        self.file = file
        self.line = line
        self.column = column
        self.arguments = arguments
        self.message = message
    }

    /// `file:line:column: severity: CODE message`，供 CLI 与日志使用。
    public var description: String {
        var location = file
        if let line { location += ":\(line)" }
        if let column { location += ":\(column)" }
        return "\(location): \(severity.rawValue): \(code) \(message)"
    }
}

extension AetherErrorCode {
    public static let cfgUndecodable: AetherErrorCode = "CFG-001"
    public static let cfgUnknownSection: AetherErrorCode = "CFG-002"
    public static let cfgUnknownKey: AetherErrorCode = "CFG-003"
    public static let cfgSyntax: AetherErrorCode = "CFG-004"
    public static let cfgDuplicateGeneralKey: AetherErrorCode = "CFG-005"
    public static let cfgDuplicatePolicy: AetherErrorCode = "CFG-010"
    public static let cfgUnknownPolicy: AetherErrorCode = "CFG-011"
    public static let cfgGroupCycle: AetherErrorCode = "CFG-012"
    public static let cfgGroupWithoutMembers: AetherErrorCode = "CFG-013"
    public static let cfgInvalidValue: AetherErrorCode = "CFG-020"
    public static let cfgMissingParameter: AetherErrorCode = "CFG-021"
    public static let cfgUnsupportedProxyType: AetherErrorCode = "CFG-022"
    public static let cfgUnsupportedCipher: AetherErrorCode = "CFG-023"
    public static let cfgIgnoredOnIOS: AetherErrorCode = "CFG-024"
    public static let cfgUnknownRuleType: AetherErrorCode = "CFG-030"
    public static let cfgRuleUnsupportedOnIOS: AetherErrorCode = "CFG-031"
    public static let cfgInvalidCIDR: AetherErrorCode = "CFG-032"
    public static let cfgInvalidRegex: AetherErrorCode = "CFG-033"
    public static let cfgInvalidPort: AetherErrorCode = "CFG-034"
    public static let cfgMissingFinal: AetherErrorCode = "CFG-035"
    public static let cfgRuleAfterFinal: AetherErrorCode = "CFG-036"
    public static let cfgInvalidRuleOption: AetherErrorCode = "CFG-037"
    public static let cfgInvalidHost: AetherErrorCode = "CFG-040"
    public static let cfgInvalidRewrite: AetherErrorCode = "CFG-050"
    public static let cfgInvalidScript: AetherErrorCode = "CFG-060"
    public static let cfgInvalidCron: AetherErrorCode = "CFG-061"
    public static let cfgDuplicateScript: AetherErrorCode = "CFG-062"
    public static let cfgMITMWildcardAll: AetherErrorCode = "CFG-070"
    public static let cfgInvalidMITMHostname: AetherErrorCode = "CFG-071"
    public static let cfgModuleSectionNotAllowed: AetherErrorCode = "CFG-080"
    public static let cfgModuleArgumentMissing: AetherErrorCode = "CFG-081"
    public static let cfgModuleRequirementIgnored: AetherErrorCode = "CFG-082"
    public static let cfgInsecureResource: AetherErrorCode = "CFG-090"
    public static let cfgInvalidResourceURL: AetherErrorCode = "CFG-091"
    public static let cfgCompatibilityNote: AetherErrorCode = "CFG-099"
}

/// 04 §13 的诊断码表：码 → 级别。
public enum DiagnosticCatalog {
    public static let severities: [AetherErrorCode: Diagnostic.Severity] = [
        .cfgUndecodable: .error,
        .cfgUnknownSection: .warning,
        .cfgUnknownKey: .warning,
        .cfgSyntax: .error,
        .cfgDuplicateGeneralKey: .warning,
        .cfgDuplicatePolicy: .error,
        .cfgUnknownPolicy: .error,
        .cfgGroupCycle: .error,
        .cfgGroupWithoutMembers: .error,
        .cfgInvalidValue: .error,
        .cfgMissingParameter: .error,
        .cfgUnsupportedProxyType: .warning,
        .cfgUnsupportedCipher: .warning,
        .cfgIgnoredOnIOS: .info,
        .cfgUnknownRuleType: .error,
        .cfgRuleUnsupportedOnIOS: .warning,
        .cfgInvalidCIDR: .error,
        .cfgInvalidRegex: .error,
        .cfgInvalidPort: .error,
        .cfgMissingFinal: .warning,
        .cfgRuleAfterFinal: .warning,
        .cfgInvalidRuleOption: .warning,
        .cfgInvalidHost: .error,
        .cfgInvalidRewrite: .error,
        .cfgInvalidScript: .error,
        .cfgInvalidCron: .error,
        .cfgDuplicateScript: .warning,
        .cfgMITMWildcardAll: .warning,
        .cfgInvalidMITMHostname: .error,
        .cfgModuleSectionNotAllowed: .warning,
        .cfgModuleArgumentMissing: .error,
        .cfgModuleRequirementIgnored: .info,
        .cfgModuleSystemMismatch: .warning,
        .cfgModuleMissingName: .warning,
        .cfgInsecureResource: .warning,
        .cfgInvalidResourceURL: .error,
        .cfgCompatibilityNote: .info,
    ]

    public static func severity(of code: AetherErrorCode) -> Diagnostic.Severity {
        severities[code] ?? .error
    }
}

extension Array where Element == Diagnostic {
    /// 是否含 error 级诊断（有则不得提交为运行包，04 §13）。
    public var containsErrors: Bool { contains { $0.severity == .error } }
}
