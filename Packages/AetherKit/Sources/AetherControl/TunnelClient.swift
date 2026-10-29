import AetherFoundation
import AetherIPC
import Foundation
@preconcurrency import NetworkExtension

/// App 与小组件使用的隧道 IPC 客户端接口（docs/10 §2）。界面只依赖本协议，预览使用 `MockTunnelClient`。
public protocol TunnelClientProtocol: Sendable {
    /// `getStatus`。隧道未运行时抛 `IPC-001`，界面据此显示「未连接」而不弹错误。
    func status() async throws -> TunnelStatus
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
}
