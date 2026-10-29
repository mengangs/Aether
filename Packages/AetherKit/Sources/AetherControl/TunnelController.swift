import AetherFoundation
import AetherIPC
import Foundation
@preconcurrency import NetworkExtension
import Observation

/// 界面上的连接状态（docs/10 §4 第 5 步）。
public enum TunnelConnectionState: Equatable, Sendable {
    /// 正在读取系统中的 VPN 配置。
    case loading
    /// 未安装 VPN 配置。
    case notInstalled
    case disconnected
    case connecting
    case connected(since: Date?)
    case reasserting
    case disconnecting
    /// 系统报告配置无效（如被删除或签名变化）。
    case invalid

    public var isActive: Bool {
        switch self {
        case .connecting, .connected, .reasserting: return true
        default: return false
        }
    }
}

/// 隧道管理中的错误，带给用户的说明与是否建议重新安装 VPN 配置。
public struct TunnelControlError: Equatable, Sendable {
    /// Aether 错误码（来自隧道的启动失败等）；系统错误时为 nil。
    public var code: String?
    public var message: String
    public var suggestsReinstall: Bool

    public init(code: String? = nil, message: String, suggestsReinstall: Bool = false) {
        self.code = code
        self.message = message
        self.suggestsReinstall = suggestsReinstall
    }
}

/// 隧道控制接口。界面只依赖本协议，预览使用 `MockTunnelController`。
@MainActor
public protocol TunnelControlling: AnyObject {
    var state: TunnelConnectionState { get }
    var lastError: TunnelControlError? { get }
    /// 停止时暂停了按需连接（界面提示「按需连接已暂停」）。
    var onDemandPaused: Bool { get }
    func refresh() async
    func start() async
    func stop() async
    func reinstall() async
}

/// App 侧隧道管理（docs/10 §4）：安装、启动、停止 VPN 配置并跟踪状态。App 与小组件 / Intent 共用。
@MainActor
@Observable
public final class TunnelController: TunnelControlling {
    public private(set) var state: TunnelConnectionState = .loading
    public private(set) var lastError: TunnelControlError?
    public private(set) var onDemandPaused = false

    /// IPC 传输，`TunnelClient` 使用；随配置加载更新会话。
    public let transport: ProviderSessionTransport

    @ObservationIgnored private let environment: AppEnvironment
    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var statusObserver: (any NSObjectProtocol)?

    public init(environment: AppEnvironment, transport: ProviderSessionTransport = ProviderSessionTransport()) {
        self.environment = environment
        self.transport = transport
    }

    /// 读取系统中的 VPN 配置并开始监听状态变化。
    public func refresh() async {
        observeStatusChanges()
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            setManager(
                managers.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier
                        == environment.tunnelBundleIdentifier
                })
        } catch {
            setManager(nil)
            lastError = Self.describe(error)
        }
    }

    public func start() async {
        lastError = nil
        do {
            let manager = try await installedManager()
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            onDemandPaused = false
            try manager.connection.startVPNTunnel(options: ["source": "app" as NSString])
        } catch {
            lastError = Self.describe(error)
        }
        updateState()
    }

    public func stop() async {
        guard let manager else { return }
        do {
            if manager.isOnDemandEnabled {
                // 按需连接开启时直接停止会被系统立即重连（docs/10 §4 第 4 步）。
                manager.isOnDemandEnabled = false
                try await manager.saveToPreferences()
                onDemandPaused = true
            }
        } catch {
            lastError = Self.describe(error)
        }
        manager.connection.stopVPNTunnel()
        updateState()
    }

    /// 删除现有配置并重新安装（授权被拒、配置失效时由用户触发）。
    public func reinstall() async {
        lastError = nil
        do {
            if let manager {
                try await manager.removeFromPreferences()
            }
            setManager(nil)
            _ = try await installedManager()
        } catch {
            lastError = Self.describe(error)
        }
        updateState()
    }

    // MARK: - 内部

    /// 返回已安装的配置；没有则创建（首次保存会弹出系统的「添加 VPN 配置」授权）。
    private func installedManager() async throws -> NETunnelProviderManager {
        if let manager {
            return manager
        }
        let manager = NETunnelProviderManager()
        let configuration = NETunnelProviderProtocol()
        configuration.providerBundleIdentifier = environment.tunnelBundleIdentifier
        configuration.serverAddress = "Aether"
        configuration.disconnectOnSleep = false
        configuration.includeAllNetworks = false
        manager.protocolConfiguration = configuration
        manager.localizedDescription = "Aether"
        manager.isEnabled = true
        try await manager.saveToPreferences()
        // 保存后必须重新加载才能启动（docs/10 §4 第 2 步）。
        try await manager.loadFromPreferences()
        setManager(manager)
        return manager
    }

    private func setManager(_ newManager: NETunnelProviderManager?) {
        manager = newManager
        transport.update(session: newManager?.connection as? NETunnelProviderSession)
        updateState()
    }

    private func observeStatusChanges() {
        guard statusObserver == nil else { return }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange, object: nil, queue: .main
        ) { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.statusDidChange()
            }
        }
    }

    private func statusDidChange() {
        let previous = state
        updateState()
        if previous.isActive, state == .disconnected, let manager {
            Task { await self.fetchDisconnectError(from: manager) }
        }
    }

    private func fetchDisconnectError(from manager: NETunnelProviderManager) async {
        do {
            try await manager.connection.fetchLastDisconnectError()
        } catch {
            lastError = Self.describe(error)
        }
    }

    private func updateState() {
        guard let manager else {
            state = .notInstalled
            return
        }
        state = Self.state(for: manager.connection.status, connectedDate: manager.connection.connectedDate)
    }

    /// `NEVPNStatus` → 界面状态。
    nonisolated static func state(for status: NEVPNStatus, connectedDate: Date?) -> TunnelConnectionState {
        switch status {
        case .invalid: return .invalid
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .connected: return .connected(since: connectedDate)
        case .reasserting: return .reasserting
        case .disconnecting: return .disconnecting
        @unknown default: return .disconnected
        }
    }

    /// 把系统或隧道的错误转为给用户的说明。
    nonisolated static func describe(_ error: any Error) -> TunnelControlError {
        let nsError = error as NSError
        if nsError.domain == "Aether", let code = nsError.userInfo["AetherErrorCode"] as? String {
            return TunnelControlError(code: code, message: nsError.localizedDescription)
        }
        if nsError.domain == NEVPNErrorDomain, let code = NEVPNError.Code(rawValue: nsError.code) {
            switch code {
            case .configurationReadWriteFailed:
                return TunnelControlError(
                    message: "无法保存 VPN 配置。可能拒绝了「添加 VPN 配置」的授权，请重新安装 VPN 配置后允许。",
                    suggestsReinstall: true)
            case .configurationInvalid, .configurationStale, .configurationUnknown:
                return TunnelControlError(message: "VPN 配置已失效，请重新安装。", suggestsReinstall: true)
            case .configurationDisabled:
                return TunnelControlError(message: "VPN 配置已被停用。", suggestsReinstall: true)
            case .connectionFailed:
                return TunnelControlError(message: "隧道启动失败：\(nsError.localizedDescription)")
            @unknown default:
                break
            }
        }
        return TunnelControlError(message: nsError.localizedDescription)
    }
}
