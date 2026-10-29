import Foundation

/// 稳定错误码（docs/02 §8.1）。格式为 `<命名空间>-<三位数字>`，如 `NET-002`；一经发布不得改变含义。
///
/// 各模块在 `AetherErrorCode` 的扩展中定义自己的码，并同步写入对应文档的错误码表。
public struct AetherErrorCode: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    /// 错误码命名空间。
    public enum Namespace: String, CaseIterable, Sendable {
        /// 配置诊断（docs/04 §13）。
        case cfg = "CFG"
        /// 连接。
        case net = "NET"
        case dns = "DNS"
        case tls = "TLS"
        case mitm = "MITM"
        /// 脚本。
        case scr = "SCR"
        /// 进程通信与运行环境。
        case ipc = "IPC"
        /// 外部资源。
        case res = "RES"
        /// 存储。
        case sto = "STO"
    }

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    /// 错误码所属命名空间；格式不合法时为 nil。
    public var namespace: Namespace? {
        guard isWellFormed, let dash = rawValue.firstIndex(of: "-") else { return nil }
        return Namespace(rawValue: String(rawValue[..<dash]))
    }

    /// 是否符合 `<命名空间>-<三位数字>` 格式。
    public var isWellFormed: Bool {
        let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, Namespace(rawValue: String(parts[0])) != nil else { return false }
        return parts[1].count == 3 && parts[1].allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// 所有可展示给用户或写入请求记录的错误都实现本协议（docs/02 §8.1）。
public protocol AetherErrorProtocol: Error, Sendable {
    /// 稳定错误码。界面文案由 App 按错误码本地化。
    var code: AetherErrorCode { get }
    /// 重试是否可能成功。
    var isRetryable: Bool { get }
    /// 调试信息（英文），不得包含密码、密钥、Cookie 等敏感信息。
    var debugDetails: String { get }
}

extension AetherErrorProtocol {
    public var isRetryable: Bool { false }
}

extension AetherErrorProtocol {
    /// 转换为可交给系统 API（如 Packet Tunnel 的 completionHandler）的 NSError：
    /// 域 `Aether`，错误码为码中的数字部分，`userInfo["AetherErrorCode"]` 为完整错误码。
    public var nsError: NSError {
        let number = Int(code.rawValue.split(separator: "-").last ?? "") ?? 0
        return NSError(
            domain: "Aether",
            code: number,
            userInfo: [
                NSLocalizedDescriptionKey: "\(code.rawValue): \(debugDetails)",
                "AetherErrorCode": code.rawValue,
            ]
        )
    }
}
