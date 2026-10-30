import AetherEngine
import AetherFoundation
import AetherIPC
import AetherKeychain
import AetherRules
import AetherStore
import Foundation
@preconcurrency import NetworkExtension

/// Packet Tunnel 扩展的核心（docs/06 §1–§2）。`PacketTunnelProvider` 只把系统回调转发到这里。
///
/// 与平台无关的生命周期（运行包、编译、状态、引擎、IPC、快照）在 `TunnelRuntime`；本类负责 NetworkExtension
/// 的网络设置、utun 描述符或备用桥接、hev 线程、路径监控、内存压力源、Darwin 通知与定期维护。
public final class PacketTunnelCore: @unchecked Sendable {
    /// 启动超过此时间视为失败（docs/06 §2.2）。
    static let startTimeout: Duration = .seconds(15)
    /// 停止时等待 hev 线程退出的上限（docs/06 §2.3）。
    static let hevExitTimeout: Duration = .seconds(3)
    /// 定期维护间隔（状态快照的流量字段，docs/10 §3）。
    static let maintenanceInterval: Duration = .seconds(30)

    private struct Components {
        var runtime: TunnelRuntime?
        var hev: HevTunnel?
        var hevExit: ExitSignal?
        var bridge: PacketFlowBridge?
        var pathMonitor: PathMonitor?
        var memorySource: (any DispatchSourceMemoryPressure)?
        var maintenance: Task<Void, Never>?
        var stopping = false
    }

    private weak var provider: NEPacketTunnelProvider?
    private let clock: @Sendable () -> Date
    private let components = Locked(Components())
    private let logger = Logger(label: "AetherTunnel")

    public init(provider: NEPacketTunnelProvider, clock: @escaping @Sendable () -> Date = Date.init) {
        self.provider = provider
        self.clock = clock
    }

    /// IPC 分发器：运行时存在时交给它；否则只回答 `getStatus`（idle），其它命令返回 `IPC-001`。
    public var dispatcher: IPCDispatcher {
        let clock = self.clock
        return IPCDispatcher { [weak self] command in
            if let runtime = self?.components.withLock({ $0.runtime }) {
                return try await runtime.handle(command)
            }
            guard case .getStatus = command else { throw IPCError.tunnelNotRunning }
            let now = clock()
            return .status(TunnelStatus(state: .idle, since: now, updatedAt: now))
        }
    }

    // MARK: - 启动（docs/06 §2.2）

    /// `startTunnel(options:completionHandler:)`。completion 恰好调用一次；超过 15 秒视为失败。
    public func start(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let completion = OneShot<Error?>(completionHandler)
        let source = (options?["source"] as? String) ?? "system"
        Task {
            try? await Task.sleep(for: Self.startTimeout)
            let error = IPCError(code: .ipcTimeout, message: "Tunnel start took longer than 15 s")
            if completion(error.nsError) {
                await self.teardown(reason: "start timeout", failure: error)
            }
        }
        Task {
            do {
                try await self.run(source: source)
                _ = completion(nil)
            } catch {
                let ipcError = IPCError(error)
                if completion(ipcError.nsError) {
                    await self.teardown(reason: "start failed", failure: ipcError)
                }
            }
        }
    }

    private func run(source: String) async throws {
        // 第 1 步：环境、容器、日志、Keychain 访问组、RLIMIT_NOFILE。
        let environment = try AppEnvironment.fromMainBundle()
        let container: SharedContainer
        do {
            container = try SharedContainer.locate(appGroupIdentifier: environment.appGroupIdentifier) {
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
            }
        } catch {
            AetherLogging.bootstrap(
                .init(subsystem: environment.bundleIdentifierPrefix, fileDirectory: nil, fileBaseName: "tunnel"))
            throw error
        }
        AetherLogging.bootstrap(
            .init(subsystem: environment.bundleIdentifierPrefix, fileDirectory: container.logs, fileBaseName: "tunnel"))
        logger.notice("Tunnel starting", metadata: ["source": "\(source)"])
        _ = environment.resolvingKeychainAccessGroupForCurrentProcess(logger: logger)
        let fileLimit = ResourceLimits.raiseOpenFileLimit()
        logger.notice("Open file limit", metadata: ["soft": "\(fileLimit.map(String.init) ?? "unknown")"])
        guard let provider else {
            throw IPCError(code: .ipcInvalidState, message: "Provider released during start")
        }

        // 第 8 步的路径监控先启动，使引擎从一开始就有网络快照。
        let pathMonitor = PathMonitor { [weak self] _ in
            guard let runtime = self?.components.withLock({ $0.runtime }) else { return }
            Task { await runtime.networkChanged() }
        }
        pathMonitor.start()

        var hooks = TunnelRuntime.Hooks()
        hooks.notify = DarwinNotifier.post
        hooks.memory = MemoryProbe.read
        hooks.hevStatistics = {
            let statistics = HevTunnel.statistics
            return HevStatisticsSummary(
                txPackets: UInt64(max(0, statistics.txPackets)), txBytes: UInt64(max(0, statistics.txBytes)),
                rxPackets: UInt64(max(0, statistics.rxPackets)), rxBytes: UInt64(max(0, statistics.rxBytes)))
        }
        hooks.systemDNSServers = SystemDNS.servers
        hooks.network = { pathMonitor.current }
        hooks.ipv4Available = { pathMonitor.current.supportsIPv4 }
        hooks.reassert = { [weak self] settings, hev, restartHev in
            try await self?.reassert(settings: settings, hev: hev, restartHev: restartHev)
        }
        let runtime = TunnelRuntime(
            container: container, notificationPrefix: environment.bundleIdentifierPrefix, hooks: hooks, clock: clock,
            logger: logger)
        components.withLock {
            $0.runtime = runtime
            $0.pathMonitor = pathMonitor
        }

        // 第 2–5 步。
        let started = try await runtime.start()
        // 第 6 步：网络设置。
        try await provider.setTunnelNetworkSettings(NetworkSettingsBuilder.makeSettings(from: started.settings))
        // 第 7 步：utun 描述符（或备用桥接）与 hev。
        let descriptor = try await tunDescriptor(provider: provider, runtime: runtime)
        startHev(configuration: started.hev, descriptor: descriptor, runtime: runtime)
        // 第 8 步：内存压力源与定期维护。
        startMemoryPressureSource(runtime: runtime)
        let maintenance = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.maintenanceInterval)
                if Task.isCancelled { break }
                await runtime.maintenance()
            }
        }
        components.withLock { $0.maintenance = maintenance }
        // 第 9 步。
        await runtime.didStart()
        logger.notice("Tunnel running")
    }

    private func tunDescriptor(provider: NEPacketTunnelProvider, runtime: TunnelRuntime) async throws -> Int32 {
        if let descriptor = UTun.findDescriptor() {
            return descriptor
        }
        let bridge = try PacketFlowBridge(flow: provider.packetFlow)
        bridge.start()
        components.withLock { $0.bridge = bridge }
        await runtime.record(.warning, .tunnel, "utun descriptor not found; using the socketpair bridge")
        return bridge.hevDescriptor
    }

    private func startHev(configuration: HevConfiguration, descriptor: Int32, runtime: TunnelRuntime) {
        let hev = HevTunnel(configuration: configuration, descriptor: descriptor)
        let exit = ExitSignal()
        components.withLock {
            $0.hev = hev
            $0.hevExit = exit
        }
        hev.start { [weak self] code, expected in
            exit.signal()
            guard !expected, let self else { return }
            let error = IPCError(code: .ipcInvalidState, message: "hev-socks5-tunnel exited unexpectedly (\(code))")
            Task {
                await runtime.record(.error, .tunnel, error.message, code: error.code)
                self.provider?.cancelTunnelWithError(error.nsError)
            }
        }
    }

    private func startMemoryPressureSource(runtime: TunnelRuntime) {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global())
        let box = UncheckedSendable(source)
        source.setEventHandler {
            let event = box.value.data
            let level: TunnelRuntime.MemoryPressure = event.contains(.critical) ? .critical : .warning
            Task { await runtime.handleMemoryPressure(level) }
        }
        components.withLock { $0.memorySource = source }
        source.resume()
    }

    // MARK: - 重载时重新应用网络设置（docs/06 §2.4 第 2 步）

    private func reassert(settings: TunnelNetworkSettingsSpec, hev configuration: HevConfiguration, restartHev: Bool)
        async throws
    {
        guard let provider else { throw IPCError(code: .ipcInvalidState, message: "Provider released") }
        provider.reasserting = true
        defer { provider.reasserting = false }
        try await provider.setTunnelNetworkSettings(NetworkSettingsBuilder.makeSettings(from: settings))
        guard restartHev, let runtime = components.withLock({ $0.runtime }) else { return }
        let (hev, exit) = components.withLock { ($0.hev, $0.hevExit) }
        hev?.stop()
        _ = await exit?.wait(timeout: Self.hevExitTimeout)
        startHev(configuration: configuration, descriptor: hev?.descriptor ?? -1, runtime: runtime)
    }

    // MARK: - 停止（docs/06 §2.3）

    /// `stopTunnel(with:completionHandler:)`。
    public func stop(reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        let done = UncheckedSendable(completionHandler)
        Task {
            await self.teardown(reason: "stop reason \(reason.rawValue)", failure: nil)
            done.value()
        }
    }

    /// 停止 hev（等待最多 3 秒）、路径监控、内存压力源与维护任务，交给运行时关闭引擎并落盘，最后关闭备用桥接。
    private func teardown(reason: String, failure: IPCError?) async {
        let parts = components.withLock { components -> Components? in
            guard !components.stopping else { return nil }
            components.stopping = true
            return components
        }
        guard let parts else { return }
        logger.notice("Tunnel stopping", metadata: ["reason": "\(reason)"])
        parts.maintenance?.cancel()
        parts.memorySource?.cancel()
        parts.pathMonitor?.cancel()
        if let hev = parts.hev {
            hev.stop()
            if await parts.hevExit?.wait(timeout: Self.hevExitTimeout) == false {
                logger.error("hev-socks5-tunnel did not exit within 3 s")
            }
        }
        if let runtime = parts.runtime {
            if let failure {
                await runtime.failStart(failure)
            } else {
                await runtime.stop(reason: reason)
            }
        }
        parts.bridge?.close()
        components.withLock { $0 = Components() }
    }

    // MARK: - 休眠、唤醒与 App 消息

    /// `sleep(completionHandler:)`：落盘统计与日志簿（docs/06 §2.5）。
    public func sleep(completionHandler: @escaping () -> Void) {
        let done = UncheckedSendable(completionHandler)
        let runtime = components.withLock { $0.runtime }
        Task {
            await runtime?.sleep()
            done.value()
        }
    }

    /// `wake()`：网络修订号加一（docs/06 §2.5）。
    public func wake() {
        components.withLock { $0.pathMonitor }?.bumpRevision()
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
}
