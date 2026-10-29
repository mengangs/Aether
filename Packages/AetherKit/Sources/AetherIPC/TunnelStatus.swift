import AetherFoundation
import Foundation

/// 隧道状态快照（docs/10 §3）：既是 `getStatus` 的返回结构，也是 `State/tunnel-status.json` 的内容。
public struct TunnelStatus: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    /// 快照的写者。正常为隧道；隧道异常退出后由 App 改写为 idle（单写者原则的唯一例外）。
    public enum Writer: String, Codable, Sendable {
        case tunnel
        case app
    }

    public var schemaVersion: Int
    public var writer: Writer
    public var state: TunnelState
    /// 进入当前状态的时间。
    public var since: Date
    public var updatedAt: Date
    public var profile: ProfileSummary?
    public var outboundMode: OutboundMode
    public var globalPolicy: String?
    public var features: FeatureFlags
    public var network: NetworkSummary
    public var traffic: TrafficSummary
    /// 配置中前 3 个非隐藏的 select 组。
    public var primaryGroups: [PolicyGroupSummary]
    public var alerts: [StatusAlert]
    public var lastError: IPCError?

    public init(
        writer: Writer = .tunnel,
        state: TunnelState,
        since: Date,
        updatedAt: Date,
        profile: ProfileSummary? = nil,
        outboundMode: OutboundMode = .rule,
        globalPolicy: String? = nil,
        features: FeatureFlags = FeatureFlags(),
        network: NetworkSummary = NetworkSummary(),
        traffic: TrafficSummary = TrafficSummary(),
        primaryGroups: [PolicyGroupSummary] = [],
        alerts: [StatusAlert] = [],
        lastError: IPCError? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.writer = writer
        self.state = state
        self.since = since
        self.updatedAt = updatedAt
        self.profile = profile
        self.outboundMode = outboundMode
        self.globalPolicy = globalPolicy
        self.features = features
        self.network = network
        self.traffic = traffic
        self.primaryGroups = primaryGroups
        self.alerts = alerts
        self.lastError = lastError
    }
}

/// 隧道生命周期状态（docs/06 §2.1）。
public enum TunnelState: String, Codable, Sendable, CaseIterable {
    case idle
    case starting
    case running
    case reloading
    case reasserting
    case stopping
    case failed
}

/// 出站模式：规则 / 全局代理 / 直连。
public enum OutboundMode: String, Codable, Sendable, CaseIterable {
    case rule
    case global
    case direct
}

public struct ProfileSummary: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var revision: String

    public init(id: String, name: String, revision: String) {
        self.id = id
        self.name = name
        self.revision = revision
    }
}

/// 四个运行时功能开关（docs/10 §2.2 `setFeature`）。
public struct FeatureFlags: Codable, Sendable, Equatable {
    public var mitm: Bool
    public var rewrite: Bool
    public var scripting: Bool
    public var capture: Bool

    public init(mitm: Bool = false, rewrite: Bool = true, scripting: Bool = true, capture: Bool = false) {
        self.mitm = mitm
        self.rewrite = rewrite
        self.scripting = scripting
        self.capture = capture
    }
}

public struct NetworkSummary: Codable, Sendable, Equatable {
    /// `wifi` / `cellular` / `wired` / `other`；未知时为 nil。
    public var interfaceType: String?
    /// 缺少 wifi-info 能力或不在 Wi-Fi 下时为 nil。
    public var ssid: String?
    /// 网络环境修订号，每次网络变化加一。
    public var revision: Int

    public init(interfaceType: String? = nil, ssid: String? = nil, revision: Int = 0) {
        self.interfaceType = interfaceType
        self.ssid = ssid
        self.revision = revision
    }
}

public struct TrafficSummary: Codable, Sendable, Equatable {
    public var upBps: Int64
    public var downBps: Int64
    public var sessionUpBytes: Int64
    public var sessionDownBytes: Int64

    public init(upBps: Int64 = 0, downBps: Int64 = 0, sessionUpBytes: Int64 = 0, sessionDownBytes: Int64 = 0) {
        self.upBps = upBps
        self.downBps = downBps
        self.sessionUpBytes = sessionUpBytes
        self.sessionDownBytes = sessionDownBytes
    }
}

public struct PolicyGroupSummary: Codable, Sendable, Equatable {
    public var name: String
    public var current: String?
    public var latencyMs: Int?

    public init(name: String, current: String?, latencyMs: Int? = nil) {
        self.name = name
        self.current = current
        self.latencyMs = latencyMs
    }
}

public struct StatusAlert: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    public var code: AetherErrorCode
    public var severity: Severity

    public init(code: AetherErrorCode, severity: Severity) {
        self.code = code
        self.severity = severity
    }
}
