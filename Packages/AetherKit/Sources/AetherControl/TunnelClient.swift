import AetherFoundation
import AetherIPC
import Foundation
@preconcurrency import NetworkExtension

/// App 与小组件使用的隧道 IPC 客户端接口（docs/10 §2）。界面只依赖本协议，预览使用 `MockTunnelClient`。
public protocol TunnelClientProtocol: Sendable {
    /// `getStatus`。隧道未运行时抛 `IPC-001`，界面据此显示「未连接」而不弹错误。
    func status() async throws -> TunnelStatus
    func memoryInfo() async throws -> MemoryInfo
    func reloadProfile(expectedRevision: String?) async throws -> ReloadResult
    func setOutboundMode(_ mode: OutboundMode) async throws
    func setGlobalPolicy(_ policy: String) async throws
    func policies() async throws -> PolicyList
    func selectPolicy(group: String, policy: String) async throws
    func traffic() async throws -> TrafficReport
    func requests(kind: RequestListKind, sinceID: UInt64?, limit: Int) async throws -> RequestPage
    /// `testPolicies`（docs/06 §9.2）：返回任务 ID，结果以 `testResults(taskID:since:)` 轮询。
    func testPolicies(names: [String]?, group: String?) async throws -> UInt64
    func testResults(taskID: UInt64?, since: Date?) async throws -> TestResults
    /// `updateResources`（docs/11 §5.4）：隧道自行下载；结果写入 `Resources/` 的元数据。
    func updateResources(urls: [String]?) async throws -> ResourceTask
    /// `resourcesChanged`：App 更新了缓存后通知隧道重新加载。
    func resourcesChanged(urls: [String]) async throws
}

/// 基于 `NETunnelProviderSession.sendProviderMessage` 的传输。会话由 `TunnelController` 在加载配置后更新。
public final class ProviderSessionTransport: IPCTransport, @unchecked Sendable {
    private let session = Locked<NETunnelProviderSession?>(nil)

    public init() {}

    /// 更新当前会话（配置加载、重装后调用）。
    public func update(session newSession: NETunnelProviderSession?) {
        session.withLock { $0 = newSession }
    }

    public func send(_ message: Data) async throws -> Data? {
        guard let current = session.current else { throw IPCError.tunnelNotRunning }
        switch current.status {
        case .connected, .reasserting:
            break
        default:
            throw IPCError.tunnelNotRunning
        }
        let waiter = OnceContinuation<Data?>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.start(continuation)
                do {
                    // 回调在任意队列上执行；显式标为 @Sendable，避免继承调用方的 actor 隔离。
                    try current.sendProviderMessage(message) { @Sendable response in
                        waiter.resume(returning: response)
                    }
                } catch {
                    waiter.resume(throwing: IPCError.tunnelNotRunning)
                }
            }
        } onCancel: {
            waiter.cancel()
        }
    }
}

/// 类型安全的隧道 IPC 客户端（docs/10 §2.1），App 与小组件共用。
public actor TunnelClient: TunnelClientProtocol {
    private let client: IPCClient

    public init(transport: any IPCTransport, timeout: Duration = IPCProtocol.defaultTimeout) {
        client = IPCClient(transport: transport, timeout: timeout)
    }

    public func status() async throws -> TunnelStatus {
        try await client.status()
    }

    public func memoryInfo() async throws -> MemoryInfo {
        try await client.memoryInfo()
    }

    public func reloadProfile(expectedRevision: String?) async throws -> ReloadResult {
        try await client.reloadProfile(expectedRevision: expectedRevision)
    }

    public func setOutboundMode(_ mode: OutboundMode) async throws {
        try await client.setOutboundMode(mode)
    }

    public func setGlobalPolicy(_ policy: String) async throws {
        try await client.setGlobalPolicy(policy)
    }

    public func policies() async throws -> PolicyList {
        try await client.policies()
    }

    public func selectPolicy(group: String, policy: String) async throws {
        try await client.selectPolicy(group: group, policy: policy)
    }

    public func traffic() async throws -> TrafficReport {
        try await client.traffic()
    }

    public func requests(kind: RequestListKind, sinceID: UInt64?, limit: Int) async throws -> RequestPage {
        try await client.requests(kind: kind, sinceID: sinceID, limit: limit)
    }

    public func testPolicies(names: [String]?, group: String?) async throws -> UInt64 {
        try await client.testPolicies(names: names, group: group)
    }

    public func testResults(taskID: UInt64?, since: Date?) async throws -> TestResults {
        try await client.testResults(taskID: taskID, since: since)
    }

    public func updateResources(urls: [String]?) async throws -> ResourceTask {
        try await client.updateResources(urls: urls)
    }

    public func resourcesChanged(urls: [String]) async throws {
        try await client.resourcesChanged(urls: urls)
    }
}
