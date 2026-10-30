import AetherControl
import AetherFoundation
import AetherIPC
import AetherKeychain
import Foundation
import Observation

/// 根模型（docs/12 §12）：运行环境、隧道控制、配置库与首页的 1 Hz 状态轮询。
@MainActor
@Observable
final class AppModel {
    /// 启动失败（运行环境或 App Group 不可用）。
    struct StartupFailure: Equatable {
        var code: String
        var message: String
    }

    let failure: StartupFailure?
    let controller: (any TunnelControlling)?
    @ObservationIgnored let client: (any TunnelClientProtocol)?
    /// 配置库；运行环境不可用时为 nil。
    let profiles: ProfileStore?

    /// 隧道通过 IPC 报告的状态；隧道未运行时为 nil。
    private(set) var tunnelStatus: TunnelStatus?
    private(set) var statusError: IPCError?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isForeground = true

    init(controller: any TunnelControlling, client: any TunnelClientProtocol, profiles: ProfileStore? = nil) {
        self.failure = nil
        self.controller = controller
        self.client = client
        self.profiles = profiles
    }

    init(failure: StartupFailure) {
        self.failure = failure
        self.controller = nil
        self.client = nil
        self.profiles = nil
    }

    /// 隧道是否已连接（依赖隧道的页面据此显示"未连接"占位）。
    var isConnected: Bool {
        guard let controller else { return false }
        switch controller.state {
        case .connected, .reasserting: return true
        default: return false
        }
    }

    /// 读取运行环境、定位 App Group、安装日志并创建隧道控制器。
    static func live() -> AppModel {
        let environment: AppEnvironment
        do {
            environment = try AppEnvironment.fromMainBundle()
        } catch {
            let ipc = IPCError(error)
            return AppModel(failure: StartupFailure(code: ipc.code.rawValue, message: ipc.message))
        }
        let container: SharedContainer
        do {
            container = try SharedContainer.locate(appGroupIdentifier: environment.appGroupIdentifier) {
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
            }
        } catch {
            AetherLogging.bootstrap(.init(subsystem: environment.bundleIdentifierPrefix, fileDirectory: nil, fileBaseName: "app"))
            Logger(label: "AetherApp").error("App Group unavailable", metadata: ["group": "\(environment.appGroupIdentifier)"])
            let ipc = IPCError(error)
            return AppModel(failure: StartupFailure(code: ipc.code.rawValue, message: ipc.message))
        }
        AetherLogging.bootstrap(
            .init(subsystem: environment.bundleIdentifierPrefix, fileDirectory: container.logs, fileBaseName: "app"))
        let logger = Logger(label: "AetherApp")
        let resolved = environment.resolvingKeychainAccessGroupForCurrentProcess(logger: logger)
        let controller = TunnelController(environment: resolved)
        return AppModel(
            controller: controller, client: TunnelClient(transport: controller.transport),
            profiles: ProfileStore(container: container))
    }

    func start() async {
        await controller?.refresh()
        startPolling()
    }

    /// 前台以 1 Hz 刷新状态，进入后台停止（docs/10 §3）。
    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        if foreground {
            startPolling()
        } else {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    func toggle() async {
        guard let controller else { return }
        if controller.state.isActive {
            await controller.stop()
        } else {
            await controller.start()
        }
    }

    private func startPolling() {
        guard pollTask == nil, isForeground, client != nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func pollOnce() async {
        guard let controller, let client else { return }
        guard case .connected = controller.state else {
            tunnelStatus = nil
            statusError = nil
            return
        }
        do {
            tunnelStatus = try await client.status()
            statusError = nil
        } catch let error as IPCError {
            tunnelStatus = nil
            // 隧道未运行（IPC-001）属于正常状态，不当作错误展示（docs/10 §2.2）。
            statusError = error.code == .ipcTunnelNotRunning ? nil : error
        } catch {
            statusError = IPCError(error)
        }
    }
}
