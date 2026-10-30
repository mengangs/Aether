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
    case getMemoryInfo
    /// App 提交运行包后请求重载；`expectedRevision` 与 `active.json` 不一致时返回 `IPC-012`。
    case reloadProfile(expectedRevision: String?)
    case setOutboundMode(OutboundMode)
    case setGlobalPolicy(String)
    case listPolicies
    case selectPolicy(group: String, policy: String)
    case getTraffic
    /// `limit` 超过 `IPCProtocol.maxPageSize` 时按上限处理。
    case getRequests(kind: RequestListKind, sinceID: UInt64?, limit: Int)

    /// 命令名，即编码中的 `type`。
    public var name: String {
        switch self {
        case .getStatus: return "getStatus"
        case .getMemoryInfo: return "getMemoryInfo"
        case .reloadProfile: return "reloadProfile"
        case .setOutboundMode: return "setOutboundMode"
        case .setGlobalPolicy: return "setGlobalPolicy"
        case .listPolicies: return "listPolicies"
        case .selectPolicy: return "selectPolicy"
        case .getTraffic: return "getTraffic"
        case .getRequests: return "getRequests"
        }
    }
}

extension IPCCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case params
    }

    private struct ReloadParams: Codable {
        var expectedRevision: String?
    }

    private struct ModeParams: Codable {
        var mode: OutboundMode
    }

    private struct PolicyParams: Codable {
        var policy: String
    }

    private struct SelectParams: Codable {
        var group: String
        var policy: String
    }

    private struct RequestsParams: Codable {
        var kind: RequestListKind
        var sinceID: UInt64?
        var limit: Int
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        func params<T: Decodable>(_ type: T.Type) throws -> T {
            try container.decode(type, forKey: .params)
        }
        switch type {
        case "getStatus": self = .getStatus
        case "getMemoryInfo": self = .getMemoryInfo
        case "reloadProfile":
            self = .reloadProfile(
                expectedRevision: try container.decodeIfPresent(ReloadParams.self, forKey: .params)?.expectedRevision)
        case "setOutboundMode": self = .setOutboundMode(try params(ModeParams.self).mode)
        case "setGlobalPolicy": self = .setGlobalPolicy(try params(PolicyParams.self).policy)
        case "listPolicies": self = .listPolicies
        case "selectPolicy":
            let value = try params(SelectParams.self)
            self = .selectPolicy(group: value.group, policy: value.policy)
        case "getTraffic": self = .getTraffic
        case "getRequests":
            let value = try params(RequestsParams.self)
            self = .getRequests(kind: value.kind, sinceID: value.sinceID, limit: value.limit)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "Unknown command \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .type)
        switch self {
        case .getStatus, .getMemoryInfo, .listPolicies, .getTraffic:
            break
        case .reloadProfile(let expectedRevision):
            try container.encode(ReloadParams(expectedRevision: expectedRevision), forKey: .params)
        case .setOutboundMode(let mode):
            try container.encode(ModeParams(mode: mode), forKey: .params)
        case .setGlobalPolicy(let policy):
            try container.encode(PolicyParams(policy: policy), forKey: .params)
        case .selectPolicy(let group, let policy):
            try container.encode(SelectParams(group: group, policy: policy), forKey: .params)
        case .getRequests(let kind, let sinceID, let limit):
            try container.encode(RequestsParams(kind: kind, sinceID: sinceID, limit: limit), forKey: .params)
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
    case memoryInfo(MemoryInfo)
    case reload(ReloadResult)
    case policies(PolicyList)
    case traffic(TrafficReport)
    case requests(RequestPage)
}

extension IPCPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        func value<T: Decodable>(_ type: T.Type) throws -> T {
            try container.decode(type, forKey: .value)
        }
        switch type {
        case "empty": self = .empty
        case "status": self = .status(try value(TunnelStatus.self))
        case "memoryInfo": self = .memoryInfo(try value(MemoryInfo.self))
        case "reload": self = .reload(try value(ReloadResult.self))
        case "policies": self = .policies(try value(PolicyList.self))
        case "traffic": self = .traffic(try value(TrafficReport.self))
        case "requests": self = .requests(try value(RequestPage.self))
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
        case .memoryInfo(let info):
            try container.encode("memoryInfo", forKey: .type)
            try container.encode(info, forKey: .value)
        case .reload(let result):
            try container.encode("reload", forKey: .type)
            try container.encode(result, forKey: .value)
        case .policies(let list):
            try container.encode("policies", forKey: .type)
            try container.encode(list, forKey: .value)
        case .traffic(let report):
            try container.encode("traffic", forKey: .type)
            try container.encode(report, forKey: .value)
        case .requests(let page):
            try container.encode("requests", forKey: .type)
            try container.encode(page, forKey: .value)
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
