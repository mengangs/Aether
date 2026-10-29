import AetherIPC
import Foundation
import Observation

/// 预览与测试用的隧道客户端（CLAUDE.md：SwiftUI 页面的 #Preview 使用 MockTunnelClient）。
public struct MockTunnelClient: TunnelClientProtocol {
    public var result: Result<TunnelStatus, IPCError>

    public init(result: Result<TunnelStatus, IPCError>) {
        self.result = result
    }

    /// 运行中的示例状态。
    public static var running: MockTunnelClient {
        let since = Date(timeIntervalSince1970: 1_793_347_200)
        return MockTunnelClient(
            result: .success(TunnelStatus(state: .running, since: since, updatedAt: since.addingTimeInterval(330))))
    }

    /// 隧道未运行。
    public static var notRunning: MockTunnelClient {
        MockTunnelClient(result: .failure(.tunnelNotRunning))
    }

    public func status() async throws -> TunnelStatus {
        try result.get()
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
