import AetherFoundation
import Foundation

/// 请求记录（docs/06 §12.2）。隧道内生成，App 经 IPC `getRequests` 分页增量拉取。
public struct RequestRecord: Codable, Sendable, Identifiable, Equatable {
    /// 入站种类：`tun` / `httpProxy` / `socks` / `script:<名称>`。
    public enum Inbound: Codable, Sendable, Equatable, Hashable {
        case tun
        case httpProxy
        case socks
        case script(String)

        public init(from decoder: any Decoder) throws {
            let text = try decoder.singleValueContainer().decode(String.self)
            switch text {
            case "tun": self = .tun
            case "httpProxy": self = .httpProxy
            case "socks": self = .socks
            default:
                guard text.hasPrefix("script:") else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: decoder.codingPath, debugDescription: "Unknown inbound \(text)"))
                }
                self = .script(String(text.dropFirst("script:".count)))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .tun: try container.encode("tun")
            case .httpProxy: try container.encode("httpProxy")
            case .socks: try container.encode("socks")
            case .script(let name): try container.encode("script:\(name)")
            }
        }
    }

    public enum Transport: String, Codable, Sendable {
        case tcp
        case udp
    }

    public enum AppProtocol: String, Codable, Sendable {
        case unknown
        case http
        case https
        case quic
    }

    /// 主机名来源：请求 / Fake IP / DNS 反查 / 嗅探 / 无。
    public enum HostSource: String, Codable, Sendable {
        case request
        case fakeIP
        case dnsReverse
        case sniffed
        case none
    }

    public enum State: String, Codable, Sendable {
        case active
        case completed
        case failed
    }

    /// 命中的规则。
    public struct Rule: Codable, Sendable, Equatable {
        public var raw: String
        public var file: String
        public var line: Int

        public init(raw: String, file: String, line: Int) {
            self.raw = raw
            self.file = file
            self.line = line
        }
    }

    /// 各阶段耗时（毫秒）。M2 中 `connect` 为到出站可用为止的总耗时（含代理握手），`handshake` 留空。
    public struct Timings: Codable, Sendable, Equatable {
        public var dns: Int?
        public var connect: Int?
        public var handshake: Int?
        public var firstByte: Int?

        public init(dns: Int? = nil, connect: Int? = nil, handshake: Int? = nil, firstByte: Int? = nil) {
            self.dns = dns
            self.connect = connect
            self.handshake = handshake
            self.firstByte = firstByte
        }
    }

    /// 备注上限：最多 20 条，每条不超过 200 字符（超出截断）。
    public static let maxNotes = 20
    public static let maxNoteLength = 200

    public let id: UInt64
    public var startedAt: Date
    public var endedAt: Date?
    public var inbound: Inbound
    public var transport: Transport
    public var appProtocol: AppProtocol
    public var host: String?
    public var hostSource: HostSource
    /// `ip:port` 或 `domain:port`。
    public var destination: String
    /// 实际连接的服务器地址。
    public var remoteAddress: String?
    public var method: String?
    /// HTTP 可见时（查询串按 08 的脱敏规则处理，M2 只记录到路径为止）。
    public var url: String?
    public var statusCode: Int?
    public var rule: Rule?
    /// 规则策略 → … → 最终节点。
    public var policyChain: [String]
    public var mitm: Bool
    public var timings: Timings
    public var bytesUp: UInt64
    public var bytesDown: UInt64
    public var state: State
    public var errorCode: String?
    public private(set) var notes: [String]
    /// 抓包数据的引用（M5）。
    public var captureID: String?

    public init(
        id: UInt64, startedAt: Date, inbound: Inbound, transport: Transport, destination: String,
        appProtocol: AppProtocol = .unknown, host: String? = nil, hostSource: HostSource = .none
    ) {
        self.id = id
        self.startedAt = startedAt
        self.inbound = inbound
        self.transport = transport
        self.appProtocol = appProtocol
        self.host = host
        self.hostSource = hostSource
        self.destination = destination
        policyChain = []
        mitm = false
        timings = Timings()
        bytesUp = 0
        bytesDown = 0
        state = .active
        notes = []
    }

    /// 追加备注（超过 20 条时丢弃，单条截断到 200 字符）。
    public mutating func addNote(_ note: String) {
        guard notes.count < Self.maxNotes else { return }
        notes.append(String(note.prefix(Self.maxNoteLength)))
    }
}

/// 去掉 URL 中的查询串与片段（请求记录在 info 级别只保留到路径，docs/02 §8.2）。
public enum URLRedaction {
    public static func stripQuery(_ url: String) -> String {
        if let index = url.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            return String(url[..<index])
        }
        return url
    }
}

/// `getRequests` 的列表种类。
public enum RequestListKind: String, Codable, Sendable {
    case recent
    case active
}
