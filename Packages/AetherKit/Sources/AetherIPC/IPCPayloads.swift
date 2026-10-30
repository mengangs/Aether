import AetherFoundation
import Foundation

// M2 命令的返回结构（docs/10 §2.2）。字节计数一律 64 位（docs/11 §4.5）。

/// `getMemoryInfo`：footprint、剩余额度、各组件估算、hev 统计（docs/02 §6）与系统 DNS 服务器。
public struct MemoryInfo: Codable, Sendable, Equatable {
    /// 进程 footprint；平台不提供时为 nil。
    public var footprintBytes: UInt64?
    /// `os_proc_available_memory()`；平台不提供时为 nil。
    public var availableBytes: UInt64?
    /// 各组件的估算（组件名 → 字节或条目数，键见 `components` 的说明）。
    public var components: [String: UInt64]
    public var hev: HevStatisticsSummary?
    /// 隧道当前使用的系统 DNS 服务器（诊断页，docs/12 §8）。
    public var systemDNSServers: [String]

    public init(
        footprintBytes: UInt64? = nil, availableBytes: UInt64? = nil, components: [String: UInt64] = [:],
        hev: HevStatisticsSummary? = nil, systemDNSServers: [String] = []
    ) {
        self.footprintBytes = footprintBytes
        self.availableBytes = availableBytes
        self.components = components
        self.hev = hev
        self.systemDNSServers = systemDNSServers
    }
}

/// `hev_socks5_tunnel_stats` 的收发统计。
public struct HevStatisticsSummary: Codable, Sendable, Equatable {
    public var txPackets: UInt64
    public var txBytes: UInt64
    public var rxPackets: UInt64
    public var rxBytes: UInt64

    public init(txPackets: UInt64, txBytes: UInt64, rxPackets: UInt64, rxBytes: UInt64) {
        self.txPackets = txPackets
        self.txBytes = txBytes
        self.rxPackets = rxPackets
        self.rxBytes = rxBytes
    }
}

/// 配置诊断的摘要（`reloadProfile` 与启动失败时返回）。
public struct DiagnosticSummary: Codable, Sendable, Equatable {
    public var code: AetherErrorCode
    /// `info` / `warning` / `error`。
    public var severity: String
    public var file: String
    public var line: Int?
    public var message: String

    public init(code: AetherErrorCode, severity: String, file: String, line: Int?, message: String) {
        self.code = code
        self.severity = severity
        self.file = file
        self.line = line
        self.message = message
    }
}

/// `reloadProfile`：新修订号与诊断摘要（最多 `ReloadResult.diagnosticLimit` 条）。
public struct ReloadResult: Codable, Sendable, Equatable {
    public static let diagnosticLimit = 50

    public var revision: String
    public var errorCount: Int
    public var warningCount: Int
    public var diagnostics: [DiagnosticSummary]
    /// 隧道网络设置是否随之重新应用（reasserting）。
    public var reasserted: Bool

    public init(
        revision: String, errorCount: Int, warningCount: Int, diagnostics: [DiagnosticSummary], reasserted: Bool
    ) {
        self.revision = revision
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.diagnostics = diagnostics
        self.reasserted = reasserted
    }
}

/// `listPolicies`：策略组与节点（docs/10 §2.2）。
public struct PolicyList: Codable, Sendable, Equatable {
    public struct Group: Codable, Sendable, Equatable {
        public var name: String
        /// `select` / `url-test` / `fallback` / `load-balance`。
        public var type: String
        public var members: [String]
        /// 当前解析到的成员（`select` 为当前选择）。
        public var selected: String?
        public var hidden: Bool
        /// 如"url-test 在 M3-07 之前解析到第一个成员"。
        public var note: String?

        public init(name: String, type: String, members: [String], selected: String?, hidden: Bool, note: String?) {
            self.name = name
            self.type = type
            self.members = members
            self.selected = selected
            self.hidden = hidden
            self.note = note
        }
    }

    public struct Node: Codable, Sendable, Equatable {
        public var name: String
        public var type: String
        public var supportsUDP: Bool
        public var available: Bool
        public var unavailableReason: String?
        /// 最近测速（M3）。
        public var latencyMs: Int?

        public init(
            name: String, type: String, supportsUDP: Bool, available: Bool, unavailableReason: String?,
            latencyMs: Int? = nil
        ) {
            self.name = name
            self.type = type
            self.supportsUDP = supportsUDP
            self.available = available
            self.unavailableReason = unavailableReason
            self.latencyMs = latencyMs
        }
    }

    public var groups: [Group]
    public var nodes: [Node]

    public init(groups: [Group], nodes: [Node]) {
        self.groups = groups
        self.nodes = nodes
    }
}

/// `getTraffic`：会话总量、按节点与接口的总量、最近 120 个速率样本。
public struct TrafficReport: Codable, Sendable, Equatable {
    public struct Bucket: Codable, Sendable, Equatable {
        public var policy: String
        /// `wifi` / `cellular` / `wired` / `other`。
        public var interface: String
        public var up: UInt64
        public var down: UInt64

        public init(policy: String, interface: String, up: UInt64, down: UInt64) {
            self.policy = policy
            self.interface = interface
            self.up = up
            self.down = down
        }
    }

    public struct Sample: Codable, Sendable, Equatable {
        public var at: Date
        /// 该秒的上下行字节数。
        public var up: UInt64
        public var down: UInt64

        public init(at: Date, up: UInt64, down: UInt64) {
            self.at = at
            self.up = up
            self.down = down
        }
    }

    public var sessionUpBytes: UInt64
    public var sessionDownBytes: UInt64
    public var buckets: [Bucket]
    public var samples: [Sample]

    public init(sessionUpBytes: UInt64, sessionDownBytes: UInt64, buckets: [Bucket], samples: [Sample]) {
        self.sessionUpBytes = sessionUpBytes
        self.sessionDownBytes = sessionDownBytes
        self.buckets = buckets
        self.samples = samples
    }
}

/// `getRequests`：一页请求记录与下一页游标。
public struct RequestPage: Codable, Sendable, Equatable {
    public var records: [RequestRecord]
    /// 下一页的 `sinceID`；没有更多时为 nil。
    public var next: UInt64?

    public init(records: [RequestRecord], next: UInt64?) {
        self.records = records
        self.next = next
    }
}

/// `testPolicies`：手动测速任务。
public struct TestTask: Codable, Sendable, Equatable {
    public var id: UInt64

    public init(id: UInt64) {
        self.id = id
    }
}

/// `getTestResults`：每个节点的延迟或错误与时间。
public struct TestResults: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var name: String
        public var latencyMs: Int?
        /// 失败时的错误码。
        public var errorCode: String?
        public var at: Date

        public init(name: String, latencyMs: Int?, errorCode: String?, at: Date) {
            self.name = name
            self.latencyMs = latencyMs
            self.errorCode = errorCode
            self.at = at
        }
    }

    public var entries: [Entry]
    /// 任务中尚未完成的节点数（不按任务查询时为 0）。
    public var pending: Int

    public init(entries: [Entry], pending: Int) {
        self.entries = entries
        self.pending = pending
    }
}
