import AetherFoundation
import Foundation

/// IPC 协议常量（docs/10 §2.1）。
public enum IPCProtocol {
    /// 协议主版本。隧道收到不同主版本的请求时返回 `IPC-002`。
    public static let version = 1
    /// 单条消息负载上限（256 KiB），超出返回 `IPC-005`。
    public static let maxPayloadBytes = 256 * 1024
    /// App 侧默认超时。
    public static let defaultTimeout: Duration = .seconds(5)
    /// 列表类命令的分页上限。
    public static let maxPageSize = 200
}

/// IPC 命令（docs/10 §2.2）。Codable 编码为 `{"type": "...", "params": {...}}`；随里程碑增加。
public enum IPCCommand: Sendable, Equatable {
    case getStatus

    /// 命令名，即编码中的 `type`。
    public var name: String {
        switch self {
        case .getStatus: return "getStatus"
        }
    }
}

extension IPCCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case params
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "getStatus":
            self = .getStatus
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown command \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .type)
        switch self {
        case .getStatus:
            break
        }
    }
}

/// 请求信封。
public struct IPCRequest: Codable, Sendable, Equatable {
    public var version: Int
    public let id: UUID
    public let command: IPCCommand

    public init(id: UUID = UUID(), command: IPCCommand, version: Int = IPCProtocol.version) {
        self.version = version
        self.id = id
        self.command = command
    }
}

/// 响应信封。
public struct IPCResponse: Codable, Sendable, Equatable {
    public let version: Int
    /// 与请求相同；请求无法解码时为全零 UUID。
    public let id: UUID
    public let outcome: IPCOutcome

    public init(id: UUID, outcome: IPCOutcome, version: Int = IPCProtocol.version) {
        self.version = version
        self.id = id
        self.outcome = outcome
    }

    /// 请求无法解码时使用的 id。
    public static let unknownRequestID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

/// 响应结果：`{"success": <负载>}` 或 `{"failure": <错误>}`。
public enum IPCOutcome: Sendable, Equatable {
    case success(IPCPayload)
    case failure(IPCError)
}

extension IPCOutcome: Codable {
    private enum CodingKeys: String, CodingKey {
        case success
        case failure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let payload = try container.decodeIfPresent(IPCPayload.self, forKey: .success) {
            self = .success(payload)
        } else if let error = try container.decodeIfPresent(IPCError.self, forKey: .failure) {
            self = .failure(error)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: container.codingPath, debugDescription: "Outcome has neither success nor failure"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .success(let payload):
            try container.encode(payload, forKey: .success)
        case .failure(let error):
            try container.encode(error, forKey: .failure)
        }
    }
}

/// 响应负载：`{"type": "...", "value": ...}`。
public enum IPCPayload: Sendable, Equatable {
    /// 无返回值的命令。
    case empty
    case status(TunnelStatus)
}

extension IPCPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "empty":
            self = .empty
        case "status":
            self = .status(try container.decode(TunnelStatus.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown payload \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .empty:
            try container.encode("empty", forKey: .type)
        case .status(let status):
            try container.encode("status", forKey: .type)
            try container.encode(status, forKey: .value)
        }
    }
}

/// IPC 错误（docs/10 §2.1）。`message` 是英文调试信息，界面文案由 App 按 `code` 本地化。
public struct IPCError: AetherErrorProtocol, Codable, Equatable {
    public let code: AetherErrorCode
    public let message: String
    public let details: [String: String]?

    public init(code: AetherErrorCode, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    /// 从任意错误构造：保留 Aether 错误码，其它错误归为 `IPC-012`。
    public init(_ error: any Error) {
        if let ipc = error as? IPCError {
            self = ipc
        } else if let aether = error as? any AetherErrorProtocol {
            self.init(code: aether.code, message: aether.debugDetails)
        } else {
            self.init(code: .ipcInvalidState, message: String(describing: error))
        }
    }

    public var debugDetails: String { message }

    public var isRetryable: Bool {
        code == .ipcTimeout || code == .ipcInvalidState
    }

    public static let tunnelNotRunning = IPCError(code: .ipcTunnelNotRunning, message: "Tunnel is not running")
    public static let timeout = IPCError(code: .ipcTimeout, message: "Timed out waiting for the tunnel")
    public static let noReply = IPCError(code: .ipcUndecodable, message: "The tunnel sent no reply")
}

/// IPC 消息的 JSON 编解码（日期 ISO 8601，字节 Base64）。
public enum IPCCodec {
    public static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.dataEncodingStrategy = .base64
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= IPCProtocol.maxPayloadBytes else {
            throw IPCError(
                code: .ipcPayloadTooLarge,
                message: "Payload of \(data.count) bytes exceeds \(IPCProtocol.maxPayloadBytes)"
            )
        }
        return data
    }

    public static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.dataDecodingStrategy = .base64
        return try decoder.decode(type, from: data)
    }

    private struct Envelope: Decodable {
        let version: Int
        let id: UUID
    }

    /// 只读取信封中的版本与 id，用于在完整解码前判断版本。
    public static func envelope(of data: Data) -> (version: Int, id: UUID)? {
        guard let envelope = try? decode(Envelope.self, from: data) else { return nil }
        return (envelope.version, envelope.id)
    }
}
