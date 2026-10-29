import AetherEngine
import AetherFoundation
import AetherIPC
import AetherKeychain
import Foundation
@preconcurrency import NetworkExtension

/// Packet Tunnel 扩展的核心（docs/06 §1–§2）。`PacketTunnelProvider` 只把系统回调转发到这里。
///
/// M0：空隧道。启动时读取 `AppEnvironment`、定位 App Group、安装日志、校正 Keychain 访问组，
/// 然后应用只含 `198.18.0.0/15` 路由、不改 DNS 的网络设置并进入 running；`getStatus` 返回当前状态。
/// 完整生命周期（编译运行配置、引擎、hev）在 M2-10 实现。
public final class PacketTunnelCore: @unchecked Sendable {
    private weak var provider: NEPacketTunnelProvider?
    private let status: Locked<TunnelStatus>
    private let clock: @Sendable () -> Date

    public init(provider: NEPacketTunnelProvider, clock: @escaping @Sendable () -> Date = Date.init) {
        self.provider = provider
        self.clock = clock
        let now = clock()
        status = Locked(TunnelStatus(state: .idle, since: now, updatedAt: now))
    }

    /// 当前状态快照。
    public var currentStatus: TunnelStatus {
        var snapshot = status.current
        snapshot.updatedAt = clock()
        return snapshot
    }

    /// IPC 分发器：M0 只支持 `getStatus`。
    public var dispatcher: IPCDispatcher {
        IPCDispatcher { [weak self] command in
            guard let self else { throw IPCError.tunnelNotRunning }
            switch command {
            case .getStatus:
                return .status(self.currentStatus)
            }
        }
    }

    // MARK: - 生命周期

    /// `startTunnel(options:completionHandler:)`。completion 恰好调用一次（docs/06 §2.2）。
    public func start(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = OneShot<Error?>(completionHandler)
        transition(to: .starting, error: nil)

        let environment: AppEnvironment
        do {
            environment = try AppEnvironment.fromMainBundle()
        } catch {
            fail(IPCError(error), completion: completion)
            return
        }

        let container: SharedContainer
        do {
            container = try SharedContainer.locate(appGroupIdentifier: environment.appGroupIdentifier) {
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
            }
        } catch {
            AetherLogging.bootstrap(
                .init(subsystem: environment.bundleIdentifierPrefix, fileDirectory: nil, fileBaseName: "tunnel"))
            fail(IPCError(error), completion: completion)
            return
        }

        AetherLogging.bootstrap(
            .init(subsystem: environment.bundleIdentifierPrefix, fileDirectory: container.logs, fileBaseName: "tunnel"))
        let logger = Logger(label: "AetherTunnel")
        let source = (options?["source"] as? String) ?? "system"
        logger.notice("Tunnel starting", metadata: ["source": "\(source)"])
        _ = environment.resolvingKeychainAccessGroupForCurrentProcess(logger: logger)

        guard let provider else {
            fail(IPCError(code: .ipcInvalidState, message: "Provider released during start"), completion: completion)
            return
        }
        let settings = NetworkSettingsBuilder.makeSettings(from: .emptyTunnel)
        provider.setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                logger.error("Applying network settings failed", metadata: ["error": "\(error.localizedDescription)"])
                self.fail(
                    IPCError(
                        code: .ipcInvalidState,
                        message: "setTunnelNetworkSettings failed: \(error.localizedDescription)"),
                    completion: completion
                )
                return
            }
            self.transition(to: .running, error: nil)
            logger.notice("Tunnel running (empty tunnel: 198.18.0.0/15 only, DNS unchanged)")
            completion(nil)
        }
    }

    /// `stopTunnel(with:completionHandler:)`。
    public func stop(reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        transition(to: .stopping, error: nil)
        Logger(label: "AetherTunnel").notice("Tunnel stopping", metadata: ["reason": "\(reason.rawValue)"])
        transition(to: .idle, error: nil)
        completionHandler()
    }

    /// `handleAppMessage(_:completionHandler:)`：交给 IPC 分发器，在控制面处理。
    public func handleAppMessage(_ message: Data, completionHandler: ((Data?) -> Void)?) {
        // completionHandler 由系统提供、可在任意线程调用一次；用 UncheckedSendable 带入任务。
        let reply = UncheckedSendable(completionHandler)
        let dispatcher = self.dispatcher
        Task {
            let response = await dispatcher.handle(message)
            reply.value?(response)
        }
    }

    // MARK: - 内部

    private func transition(to state: TunnelState, error: IPCError?) {
        let now = clock()
        status.withLock {
            if $0.state != state {
                $0.since = now
            }
            $0.state = state
            $0.updatedAt = now
            $0.lastError = error
        }
    }

    private func fail(_ error: IPCError, completion: OneShot<Error?>) {
        transition(to: .failed, error: error)
        Logger(label: "AetherTunnel").error(
            "Tunnel start failed", metadata: ["code": "\(error.code)", "details": "\(error.message)"])
        completion(error.nsError)
    }
}
