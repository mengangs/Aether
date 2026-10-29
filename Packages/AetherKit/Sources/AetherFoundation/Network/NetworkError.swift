/// 流的标识：隧道进程内单调递增（docs/06 §12.2 `RequestRecord.id`）。
public struct FlowID: RawRepresentable, Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static func < (lhs: FlowID, rhs: FlowID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var description: String { "#\(rawValue)" }
}

/// 连接类错误（`NET` 码，docs/06 §15）。`details` 只写调试信息，不得包含凭据。
public struct NetworkError: AetherErrorProtocol, Equatable {
    public let code: AetherErrorCode
    public let details: String

    public init(_ code: AetherErrorCode, _ details: String = "") {
        self.code = code
        self.details = details
    }

    public var debugDetails: String {
        details.isEmpty ? code.rawValue : details
    }

    public var isRetryable: Bool {
        switch code {
        case .netConnectionRefused, .netConnectTimeout, .netUnreachable, .netConnectionReset, .netResolutionFailed,
            .netMemoryPressure, .netEngineNotReady:
            return true
        default:
            return false
        }
    }
}

extension AetherErrorCode {
    /// 连接被拒绝。
    public static let netConnectionRefused: AetherErrorCode = "NET-001"
    /// 连接超时。
    public static let netConnectTimeout: AetherErrorCode = "NET-002"
    /// 网络不可达。
    public static let netUnreachable: AetherErrorCode = "NET-003"
    /// 连接被重置。
    public static let netConnectionReset: AetherErrorCode = "NET-004"
    /// 空闲超时。
    public static let netIdleTimeout: AetherErrorCode = "NET-005"
    /// 未知的 Fake IP（映射不存在）。
    public static let netUnknownFakeIP: AetherErrorCode = "NET-010"
    /// 路由所需的 DNS 解析失败。
    public static let netResolutionFailed: AetherErrorCode = "NET-011"
    /// 策略不可用（不支持的类型或参数）。
    public static let netPolicyUnavailable: AetherErrorCode = "NET-020"
    /// 策略不支持 UDP。
    public static let netPolicyNoUDP: AetherErrorCode = "NET-021"
    /// 被策略拒绝。
    public static let netRejected: AetherErrorCode = "NET-022"
    /// 代理握手失败（附 HTTP 状态码或 SOCKS 回复码）。
    public static let netProxyHandshakeFailed: AetherErrorCode = "NET-030"
    /// 代理认证失败。
    public static let netProxyAuthFailed: AetherErrorCode = "NET-031"
    /// 服务器协议错误。
    public static let netProtocolError: AetherErrorCode = "NET-032"
    /// 到代理服务器的 TLS 握手失败。
    public static let netTLSFailed: AetherErrorCode = "NET-033"
    /// 连接数超过上限。
    public static let netTooManyFlows: AetherErrorCode = "NET-040"
    /// 内存压力下拒绝。
    public static let netMemoryPressure: AetherErrorCode = "NET-041"
    /// 引擎未就绪。
    public static let netEngineNotReady: AetherErrorCode = "NET-050"
}
