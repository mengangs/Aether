import AetherIPC
import Foundation
import Observation

/// 预览与测试用的隧道客户端（CLAUDE.md：SwiftUI 页面的 #Preview 使用 MockTunnelClient）。返回固定的 fixtures；
/// `failure` 非 nil 时每个命令都抛出它。修改类命令不改变 fixtures。
public struct MockTunnelClient: TunnelClientProtocol {
    public struct Fixtures: Sendable {
        public var status: TunnelStatus
        public var memory: MemoryInfo
        public var policies: PolicyList
        public var traffic: TrafficReport
        public var requests: [RequestRecord]

        public init(
            status: TunnelStatus, memory: MemoryInfo, policies: PolicyList, traffic: TrafficReport,
            requests: [RequestRecord]
        ) {
            self.status = status
            self.memory = memory
            self.policies = policies
            self.traffic = traffic
            self.requests = requests
        }
    }

    public var fixtures: Fixtures
    public var failure: IPCError?

    public init(fixtures: Fixtures = .sample, failure: IPCError? = nil) {
        self.fixtures = fixtures
        self.failure = failure
    }

    /// 运行中，带示例数据。
    public static var running: MockTunnelClient { MockTunnelClient() }
    /// 运行中，但配置没有策略组、没有请求（空状态）。
    public static var empty: MockTunnelClient { MockTunnelClient(fixtures: .empty) }
    /// 隧道未运行。
    public static var notRunning: MockTunnelClient { MockTunnelClient(failure: .tunnelNotRunning) }
    /// 每个命令都失败（错误状态）。
    public static func failing(
        _ error: IPCError = IPCError(code: .ipcTimeout, message: "Timed out waiting for the tunnel")
    )
        -> MockTunnelClient
    {
        MockTunnelClient(failure: error)
    }

    private func value<T>(_ body: () -> T) throws -> T {
        if let failure { throw failure }
        return body()
    }

    public func status() async throws -> TunnelStatus { try value { fixtures.status } }
    public func memoryInfo() async throws -> MemoryInfo { try value { fixtures.memory } }

    public func reloadProfile(expectedRevision: String?) async throws -> ReloadResult {
        try value {
            ReloadResult(
                revision: expectedRevision ?? fixtures.status.profile?.revision ?? "", errorCount: 0, warningCount: 0,
                diagnostics: [], reasserted: false)
        }
    }

    public func setOutboundMode(_ mode: OutboundMode) async throws { try value {} }
    public func setGlobalPolicy(_ policy: String) async throws { try value {} }
    public func policies() async throws -> PolicyList { try value { fixtures.policies } }
    public func selectPolicy(group: String, policy: String) async throws { try value {} }
    public func traffic() async throws -> TrafficReport { try value { fixtures.traffic } }

    public func requests(kind: RequestListKind, sinceID: UInt64?, limit: Int) async throws -> RequestPage {
        try value {
            let pool = fixtures.requests.filter { kind == .active ? $0.state == .active : $0.state != .active }
            let page = pool.filter { $0.id > (sinceID ?? 0) }.prefix(limit)
            return RequestPage(records: Array(page), next: page.last?.id)
        }
    }
}

extension MockTunnelClient.Fixtures {
    static let base = Date(timeIntervalSince1970: 1_793_347_200)

    /// 示例数据：一个运行中的配置、两个策略组、四个节点、几条请求与 2 分钟的速率样本。
    public static var sample: Self {
        let profile = ProfileSummary(id: "6F1C0000-0000-4000-8000-000000000001", name: "Main", revision: "sha256:0123")
        let status = TunnelStatus(
            state: .running, since: base, updatedAt: base.addingTimeInterval(330), profile: profile,
            outboundMode: .rule, globalPolicy: "Proxy",
            network: NetworkSummary(interfaceType: "wifi", ssid: "Home", revision: 3),
            traffic: TrafficSummary(
                upBps: 12_400, downBps: 568_000, sessionUpBytes: 10_485_760, sessionDownBytes: 734_003_200),
            primaryGroups: [PolicyGroupSummary(name: "Proxy", current: "HK-01", latencyMs: nil)])
        let groups: [PolicyList.Group] = [
            PolicyList.Group(
                name: "Proxy", type: "select", members: ["HK-01", "JP-01", "DIRECT"], selected: "HK-01", hidden: false,
                note: nil),
            PolicyList.Group(
                name: "Auto", type: "url-test", members: ["HK-01", "JP-01"], selected: "HK-01", hidden: false,
                note: "url-test resolves to its first member until M3-07"),
        ]
        let nodes: [PolicyList.Node] = [
            PolicyList.Node(name: "HK-01", type: "https", supportsUDP: false, available: true, unavailableReason: nil),
            PolicyList.Node(name: "JP-01", type: "socks5", supportsUDP: true, available: true, unavailableReason: nil),
            PolicyList.Node(
                name: "SG-01", type: "ss", supportsUDP: true, available: false, unavailableReason: "ss arrives in M3"),
        ]
        let policies = PolicyList(groups: groups, nodes: nodes)
        var samples: [TrafficReport.Sample] = []
        for index in 0..<120 {
            let up: Int = 8_000 + (index * 37) % 9_000
            let down: Int = 200_000 + (index * 7_919) % 600_000
            let at: Date = base.addingTimeInterval(Double(index))
            samples.append(TrafficReport.Sample(at: at, up: UInt64(up), down: UInt64(down)))
        }
        let buckets: [TrafficReport.Bucket] = [
            TrafficReport.Bucket(policy: "HK-01", interface: "wifi", up: 9_437_184, down: 700_000_000),
            TrafficReport.Bucket(policy: "DIRECT", interface: "wifi", up: 1_048_576, down: 34_003_200),
        ]
        let traffic = TrafficReport(
            sessionUpBytes: 10_485_760, sessionDownBytes: 734_003_200, buckets: buckets, samples: samples)
        var https = RequestRecord(
            id: 1, startedAt: base, inbound: .tun, transport: .tcp, destination: "198.18.0.12:443")
        https.host = "www.example.com"
        https.hostSource = .fakeIP
        https.appProtocol = .https
        https.policyChain = ["Proxy", "HK-01"]
        https.rule = RequestRecord.Rule(raw: "DOMAIN-SUFFIX,example.com,Proxy", file: "Main", line: 12)
        https.remoteAddress = "203.0.113.10:443"
        https.bytesUp = 2_048
        https.bytesDown = 96_256
        https.timings.connect = 84
        https.timings.firstByte = 132
        https.state = .completed
        https.endedAt = base.addingTimeInterval(2)
        var failed = RequestRecord(
            id: 2, startedAt: base.addingTimeInterval(1), inbound: .tun, transport: .tcp, destination: "198.18.0.40:443"
        )
        failed.host = "blocked.example.net"
        failed.policyChain = ["REJECT"]
        failed.state = .failed
        failed.errorCode = "NET-022"
        failed.addNote("REJECT")
        var udp = RequestRecord(
            id: 3, startedAt: base.addingTimeInterval(2), inbound: .tun, transport: .udp, destination: "198.18.0.12:443"
        )
        udp.host = "www.example.com"
        udp.appProtocol = .quic
        udp.policyChain = ["Proxy", "JP-01"]
        udp.bytesUp = 4_800
        udp.bytesDown = 52_000
        let memory = MemoryInfo(
            footprintBytes: 18_874_368, availableBytes: 31_457_280,
            components: ["tcpFlows": 42, "udpAssociations": 3, "activeRequests": 45, "finishedRequests": 500],
            hev: HevStatisticsSummary(
                txPackets: 120_000, txBytes: 90_000_000, rxPackets: 180_000, rxBytes: 720_000_000),
            systemDNSServers: ["192.0.2.53", "2001:db8::53"])
        return Self(
            status: status, memory: memory, policies: policies, traffic: traffic, requests: [https, failed, udp])
    }

    /// 空状态：运行中，但没有策略组、没有请求、没有流量。
    public static var empty: Self {
        var fixtures = sample
        fixtures.status.primaryGroups = []
        fixtures.status.traffic = TrafficSummary()
        fixtures.policies = PolicyList(groups: [], nodes: [])
        fixtures.traffic = TrafficReport(sessionUpBytes: 0, sessionDownBytes: 0, buckets: [], samples: [])
        fixtures.requests = []
        return fixtures
    }
}

/// 预览与测试用的隧道控制器：开关直接切换状态。
@MainActor
@Observable
public final class MockTunnelController: TunnelControlling {
    public var state: TunnelConnectionState
    public var lastError: TunnelControlError?
    public var onDemandPaused: Bool

    public init(state: TunnelConnectionState, lastError: TunnelControlError? = nil, onDemandPaused: Bool = false) {
        self.state = state
        self.lastError = lastError
        self.onDemandPaused = onDemandPaused
    }

    public func refresh() async {}

    public func start() async {
        state = .connected(since: Date())
        lastError = nil
    }

    public func stop() async {
        state = .disconnected
    }

    public func reinstall() async {
        state = .disconnected
        lastError = nil
    }
}
