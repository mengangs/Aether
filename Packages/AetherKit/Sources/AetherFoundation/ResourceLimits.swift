/// 外部资源（规则集、域名集、订阅等）的上限（docs/05 §6.4、docs/11 §5.1）。
public enum ResourceLimits {
    /// 单个资源解压后的大小上限：32 MiB。
    public static let maxBytes = 32 << 20
    /// 规则集 / 域名集的条目上限：50 万。
    public static let maxEntries = 500_000
}

/// 外部资源加载失败（`RES` 类错误码，docs/11 §9）。
public enum ResourceLoadError: AetherErrorProtocol, Equatable {
    /// 超出大小上限。
    case tooLarge(bytes: Int)
    /// 超出条目上限。
    case tooManyEntries(count: Int)
    /// 没有任何有效条目。
    case noValidEntries

    public var code: AetherErrorCode {
        switch self {
        case .tooLarge, .tooManyEntries: return .resTooLarge
        case .noValidEntries: return .resNoValidEntries
        }
    }

    public var debugDetails: String {
        switch self {
        case .tooLarge(let bytes): return "Resource is \(bytes) bytes; the limit is \(ResourceLimits.maxBytes)"
        case .tooManyEntries(let count):
            return "Resource has \(count) entries; the limit is \(ResourceLimits.maxEntries)"
        case .noValidEntries: return "Resource has no valid entries"
        }
    }
}

extension AetherErrorCode {
    /// 资源超出大小或条目上限。
    public static let resTooLarge: AetherErrorCode = "RES-010"
    /// 资源没有有效条目。
    public static let resNoValidEntries: AetherErrorCode = "RES-011"
}

/// 规则集 / 域名集加载统计（用于外部资源页与日志簿）。
public struct ListLoadStatistics: Sendable, Equatable {
    public var accepted = 0
    /// 无效行（语法错误、无效值）。
    public var invalid = 0
    /// iOS 不支持的类型（如 `PROCESS-NAME`）。
    public var unsupported = 0
    /// 不允许出现在规则集中的类型（`RULE-SET`、`DOMAIN-SET`、`FINAL`）。
    public var disallowed = 0

    public init() {}

    public var skipped: Int { invalid + unsupported + disallowed }
}
