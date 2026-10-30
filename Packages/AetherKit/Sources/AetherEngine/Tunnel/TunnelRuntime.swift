import AetherDNS
import AetherFoundation
import AetherIPC
import AetherOutbound
import AetherProfile
import AetherRules
import AetherStore
import Foundation
import NIOCore

/// 隧道运行时（docs/06 §2、docs/10 §2–§3、docs/02 §6）：隧道生命周期中与平台无关的部分。
///
/// 读取运行包并编译运行配置、读写持久化状态（`State/`、Fake IP 快照、数据库）、启停引擎、处理 IPC 命令、
/// 写状态快照并发通知、处理内存压力与网络变化。`AetherTunnelSupport` 的 `PacketTunnelCore` 负责 NetworkExtension、
/// hev 与系统接口，平台动作经 `Hooks` 回调。所有方法在本 actor 上串行执行（控制面）。
public actor TunnelRuntime {
    /// 平台提供的动作与读数。
    public struct Hooks: Sendable {
        /// 重新应用隧道网络设置（reasserting）；`restartHev` 为 true（MTU 变化）时同时重启 hev。
        public var reassert:
            @Sendable (_ settings: TunnelNetworkSettingsSpec, _ hev: HevConfiguration, _ restartHev: Bool) async throws
                ->
                Void = { _, _, _ in }
        /// 发出 Darwin 通知（参数为完整的通知名）。
        public var notify: @Sendable (String) -> Void = { _ in }
        /// 进程 footprint 与剩余额度（docs/02 §6）。
        public var memory: @Sendable () -> (footprint: UInt64?, available: UInt64?) = { (nil, nil) }
        public var hevStatistics: @Sendable () -> HevStatisticsSummary? = { nil }
        public var systemDNSServers: @Sendable () -> [IPAddress] = { [] }
        public var network: @Sendable () -> NetworkSnapshot = { NetworkSnapshot() }
        /// 当前网络是否有 IPv4；设置后 DIRECT 在纯 IPv6 网络下经 `getaddrinfo` 合成 NAT64 地址（docs/06 §6 第 8 步）。
        public var ipv4Available: (@Sendable () -> Bool)?
        /// 测试用：按写法构造 DNS 上游。
        public var dnsUpstreams: (@Sendable (DNSUpstreamSpec) -> (any DNSUpstream)?)?
        /// 测试用：HTTP 代理入站监听地址（为 nil 时用 `127.0.0.1:6171`）。
        public var httpProxyAddress: (host: String, port: Int)?

        public init() {}
    }

    /// 启动结果：交给平台应用的网络设置与 hev 配置。
    public struct Started: Sendable {
        public var settings: TunnelNetworkSettingsSpec
        public var hev: HevConfiguration
    }

    public enum MemoryPressure: String, Sendable {
        case warning
        case critical
    }

    /// 缓冲中的流量增量上限：超出时丢弃最旧的（每 60 秒的增量通常只有几十条）。
    static let trafficBufferLimit = 4096
    /// 数据库清理间隔（docs/11 §4.2）。
    static let pruneInterval: TimeInterval = 6 * 3600

    public let container: SharedContainer
    let notificationPrefix: String
    let hooks: Hooks
    let clock: @Sendable () -> Date
    let logger: Logger
    private let makeThreads: @Sendable () -> EngineThreads

    private(set) var engine: Engine?
    private var configuration: RuntimeConfiguration?
    private var settings: TunnelNetworkSettingsSpec?
    private var hev: HevConfiguration?
    private var runtimeState = RuntimeStateFile()
    private var status: TunnelStatus
    private var database: AetherDatabase?
    private var logbook: LogbookWriter?
    private let trafficBuffer = Locked<[TrafficDelta]>([])
    private var lastPrune: Date?

    public init(
        container: SharedContainer, notificationPrefix: String, hooks: Hooks = Hooks(),
        clock: @escaping @Sendable () -> Date = { Date() }, logger: Logger = Logger(label: "AetherTunnel"),
        threads: @escaping @Sendable () -> EngineThreads = { EngineThreads() }
    ) {
        self.container = container
        self.notificationPrefix = notificationPrefix
        self.hooks = hooks
        self.clock = clock
        self.logger = logger
        makeThreads = threads
        let now = clock()
        status = TunnelStatus(state: .idle, since: now, updatedAt: now)
    }

    /// 状态通知名（docs/10 §3）。
    public var statusNotification: String { "\(notificationPrefix).notify.status" }
    /// 日志簿通知名。
    public var logbookNotification: String { "\(notificationPrefix).notify.logbook" }

    // MARK: - 启动与停止（docs/06 §2.2、§2.3）

    /// 第 2–5 步：读取运行包、编译、读取持久化状态、启动引擎；返回第 6–7 步需要的网络设置与 hev 配置。
    /// 失败时撤销已完成的步骤、状态置 `failed`，抛出带错误码的 `IPCError`。
    public func start() async throws -> Started {
        transition(to: .starting)
        writeStatus(notify: true)
        openDatabase()
        do {
            let bundle = try RunBundle.loadActive(from: container)
            let configuration = try compile(bundle)
            runtimeState =
                JSONStateFile.read(RuntimeStateFile.self, from: container.runtimeStateFile) ?? RuntimeStateFile()
            let selections = JSONStateFile.read(SelectionsFile.self, from: container.selectionsFile) ?? SelectionsFile()
            let credentials = SOCKS5Credentials.random()
            var options = engineOptions(profileID: bundle.manifest.profileID)
            options.socksCredentials = credentials
            let threads = makeThreads()
            options.nat64 = hooks.ipv4Available.map {
                NAT64Support.systemSynthesizer(pool: threads.blockingPool, hasIPv4: $0)
            }
            let engine = try await Engine.start(
                configuration: configuration, options: options,
                selections: selections.selections[bundle.manifest.profileID] ?? [:], threads: threads)
            self.engine = engine
            if let bytes = try? Data(contentsOf: container.fakeIPSnapshotFile) {
                let restored = try await engine.eventLoop.submit { engine.dns.loadFakeIPSnapshot(Array(bytes)) }.get()
                if !restored {
                    log(.warning, .tunnel, "Fake IP snapshot ignored (format or range changed)")
                }
            }
            try await engine.setOutboundMode(runtimeState.outboundMode)
            if let global = runtimeState.globalPolicy {
                try? await engine.setGlobalPolicy(global)
            }
            let settings = TunnelNetworkSettingsSpec.make(from: configuration)
            let hev = HevConfiguration(
                socksPort: engine.socks.port, credentials: credentials, mtu: configuration.general.tunMTU)
            self.configuration = configuration
            self.settings = settings
            self.hev = hev
            status.profile = ProfileSummary(
                id: bundle.manifest.profileID, name: bundle.manifest.profileName, revision: bundle.manifest.revision)
            await prune()
            return Started(settings: settings, hev: hev)
        } catch {
            let ipcError = IPCError(error)
            await stopEngine()
            log(.error, .tunnel, "Tunnel start failed: \(ipcError.message)", code: ipcError.code)
            await flushPersistence()
            transition(to: .failed, error: ipcError)
            writeStatus(notify: true)
            throw ipcError
        }
    }

    /// 第 9 步：平台已应用网络设置并启动 hev。
    public func didStart() {
        transition(to: .running)
        log(.info, .tunnel, "Tunnel running")
        writeStatus(notify: true)
    }

    /// 平台步骤（网络设置、hev）失败：撤销引擎，状态置 `failed`。
    public func failStart(_ error: IPCError) async {
        await stopEngine()
        log(.error, .tunnel, "Tunnel start failed: \(error.message)", code: error.code)
        await flushPersistence()
        transition(to: .failed, error: error)
        writeStatus(notify: true)
    }

    /// 停止（docs/06 §2.3 第 3–6 步；入站与 hev 由平台先停）：关闭全部流，落盘 Fake IP 快照、流量统计与日志簿，
    /// 写 `idle` 快照并通知。
    public func stop(reason: String) async {
        transition(to: .stopping)
        writeStatus(notify: false)
        await stopEngine()
        log(.info, .tunnel, "Tunnel stopped (\(reason))")
        await flushPersistence()
        transition(to: .idle)
        writeStatus(notify: true)
    }

    private func stopEngine() async {
        guard let engine else { return }
        if let bytes = try? await engine.eventLoop.submit({ engine.dns.fakeIPSnapshot() }).get() {
            try? FileManager.default.createDirectory(at: container.state, withIntermediateDirectories: true)
            try? Data(bytes).write(to: container.fakeIPSnapshotFile, options: .atomic)
        }
        await engine.stop()
        self.engine = nil
        configuration = nil
    }

    // MARK: - 重载（docs/06 §2.4）

    /// 重新读取运行包并热替换运行配置。配置有 error 级诊断时保留旧配置、写日志簿并返回诊断（`errorCount > 0`）。
    /// 网络设置变化时经 `Hooks.reassert` 重新应用（MTU 变化时重启 hev）。
    /// - Throws: `IPC-012`：隧道不在运行，或 `expectedRevision` 与 `active.json` 指向的运行包不一致。
    public func reload(expectedRevision: String?) async throws -> ReloadResult {
        guard let engine, let current = settings, let hev, status.state == .running else {
            throw IPCError(code: .ipcInvalidState, message: "Tunnel is not running")
        }
        let bundle = try RunBundle.loadActive(from: container)
        if let expectedRevision, bundle.manifest.revision != expectedRevision {
            throw IPCError(
                code: .ipcInvalidState,
                message: "Active bundle is \(bundle.manifest.revision), expected \(expectedRevision)")
        }
        transition(to: .reloading)
        writeStatus(notify: true)
        let resolved = resolve(bundle)
        let diagnostics = Self.summaries(resolved.diagnostics)
        let errorCount = resolved.diagnostics.filter { $0.severity == .error }.count
        let warningCount = resolved.diagnostics.filter { $0.severity == .warning }.count
        guard resolved.isCommittable else {
            log(.error, .profile, "Reload rejected: \(errorCount) error(s); the previous configuration stays active")
            transition(to: .running)
            writeStatus(notify: true)
            return ReloadResult(
                revision: bundle.manifest.revision, errorCount: errorCount, warningCount: warningCount,
                diagnostics: diagnostics, reasserted: false)
        }
        let configuration = RuntimeConfiguration.compile(
            resolved, profileID: bundle.manifest.profileID, profileName: bundle.manifest.profileName)
        do {
            try await engine.reload(configuration)
        } catch {
            transition(to: .running)
            writeStatus(notify: true)
            throw IPCError(error)
        }
        self.configuration = configuration
        status.profile = ProfileSummary(
            id: bundle.manifest.profileID, name: bundle.manifest.profileName, revision: bundle.manifest.revision)
        let newSettings = TunnelNetworkSettingsSpec.make(from: configuration)
        var reasserted = false
        if newSettings != current {
            var newHev = hev
            newHev.mtu = configuration.general.tunMTU
            let restartHev = newSettings.mtu != current.mtu
            transition(to: .reasserting)
            writeStatus(notify: true)
            do {
                try await hooks.reassert(newSettings, newHev, restartHev)
                settings = newSettings
                self.hev = newHev
                reasserted = true
                if restartHev {
                    log(.warning, .tunnel, "MTU changed to \(newSettings.mtu); hev restarted and TUN flows interrupted")
                }
            } catch {
                log(.error, .tunnel, "Re-applying network settings failed: \(error)")
            }
        }
        transition(to: .running)
        writeStatus(notify: true)
        return ReloadResult(
            revision: bundle.manifest.revision, errorCount: errorCount, warningCount: warningCount,
            diagnostics: diagnostics, reasserted: reasserted)
    }

    // MARK: - IPC（docs/10 §2.2）

    /// 分发器：命令在本 actor 上执行。
    public nonisolated var dispatcher: IPCDispatcher {
        IPCDispatcher { [self] command in try await self.handle(command) }
    }

    public func handle(_ command: IPCCommand) async throws -> IPCPayload {
        switch command {
        case .getStatus:
            return .status(await refreshedStatus())
        case .getMemoryInfo:
            return .memoryInfo(await memoryInfo())
        case .reloadProfile(let expectedRevision):
            return .reload(try await reload(expectedRevision: expectedRevision))
        case .setOutboundMode(let mode):
            try await requireEngine().setOutboundMode(mode)
            runtimeState.outboundMode = mode
            saveRuntimeState()
            writeStatus(notify: true)
            return .empty
        case .setGlobalPolicy(let policy):
            try await requireEngine().setGlobalPolicy(policy)
            runtimeState.globalPolicy = policy
            saveRuntimeState()
            writeStatus(notify: true)
            return .empty
        case .listPolicies:
            return .policies(try await policyList())
        case .selectPolicy(let group, let policy):
            try await requireEngine().selectPolicy(group: group, member: policy)
            writeStatus(notify: true)
            return .empty
        case .getTraffic:
            let statistics = try requireEngine().statistics
            return .traffic(
                try await statistics.eventLoop.submit {
                    TrafficReport(
                        sessionUpBytes: statistics.totalUp, sessionDownBytes: statistics.totalDown,
                        buckets: statistics.sessionBuckets,
                        samples: statistics.recentSamples.map { .init(at: $0.at, up: $0.up, down: $0.down) })
                }.get())
        case .getRequests(let kind, let sinceID, let limit):
            let requests = try requireEngine().requests
            let pageSize = min(max(limit, 1), IPCProtocol.maxPageSize)
            return .requests(
                try await requests.eventLoop.submit {
                    let page = requests.page(kind: kind, sinceID: sinceID, limit: pageSize)
                    return RequestPage(records: page.records, next: page.next)
                }.get())
        }
    }

    private func requireEngine() throws -> Engine {
        guard let engine, status.state == .running || status.state == .reasserting else {
            throw IPCError(code: .ipcInvalidState, message: "Tunnel is \(status.state.rawValue)")
        }
        return engine
    }

    private func policyList() async throws -> PolicyList {
        let engine = try requireEngine()
        let router = engine.router
        return try await engine.eventLoop.submit {
            let configuration = router.configuration
            let registry = router.dependencies.policies
            let groups = configuration.groupOrder.compactMap { name -> PolicyList.Group? in
                guard case .group(let group) = configuration.policies[name] else { return nil }
                let selected = (try? registry.resolve(name, in: configuration))?.chain.dropFirst().first
                let note: String? =
                    group.type.isAutomatic ? "\(group.type.rawValue) resolves to its first member until M3-07" : nil
                return PolicyList.Group(
                    name: name, type: group.type.rawValue, members: group.members, selected: selected,
                    hidden: group.hidden, note: note)
            }
            let nodes = configuration.proxyOrder.compactMap { name -> PolicyList.Node? in
                guard case .proxy(let node) = configuration.policies[name] else { return nil }
                return PolicyList.Node(
                    name: name, type: node.type, supportsUDP: node.supportsUDP, available: node.connector != nil,
                    unavailableReason: node.unavailableReason)
            }
            return PolicyList(groups: groups, nodes: nodes)
        }.get()
    }

    private func memoryInfo() async -> MemoryInfo {
        let memory = hooks.memory()
        var components: [String: UInt64] = [:]
        if let engine {
            let router = engine.router
            let counts = try? await engine.eventLoop.submit {
                (
                    UInt64(router.dependencies.flows.activeCount), UInt64(router.udpAssociationCount),
                    UInt64(router.dependencies.requests.activeRecords.count),
                    UInt64(router.dependencies.requests.recent.count)
                )
            }.get()
            if let counts {
                components["tcpFlows"] = counts.0
                components["udpAssociations"] = counts.1
                components["activeRequests"] = counts.2
                components["finishedRequests"] = counts.3
            }
        }
        return MemoryInfo(
            footprintBytes: memory.footprint, availableBytes: memory.available, components: components,
            hev: hooks.hevStatistics(), systemDNSServers: hooks.systemDNSServers().map(\.description))
    }

    // MARK: - 内存压力、网络变化、休眠（docs/02 §6、docs/06 §11、§2.5）

    /// warning：清空 DNS 正向缓存与反查表（保留 Fake IP 表）、请求记录环缩减到 1/4；critical：另外新流按拒绝处理 10 秒。
    /// 每次都写日志簿（含 footprint 与剩余额度）。
    public func handleMemoryPressure(_ level: MemoryPressure) async {
        if let engine {
            let router = engine.router
            try? await engine.eventLoop.submit {
                router.dependencies.dns.releaseMemory()
                router.dependencies.requests.shrinkForMemoryPressure()
                if level == .critical {
                    router.dependencies.flows.rejectNewFlows(for: .seconds(10), now: router.eventLoop.now)
                }
            }.get()
        }
        let memory = hooks.memory()
        let details =
            "{\"footprint\":\(memory.footprint.map(String.init) ?? "null"),\"available\":\(memory.available.map(String.init) ?? "null")}"
        log(
            level == .critical ? .error : .warning, .memory, "Memory pressure: \(level.rawValue)",
            code: level == .critical ? .netMemoryPressure : nil, details: details)
        await flushLogbook()
    }

    /// 网络环境变化（修订号已加一，docs/06 §11 第 1、4、6 步）：清空 DNS 正向缓存与规则决策缓存，写快照并通知。
    public func networkChanged() async {
        if let engine {
            let router = engine.router
            try? await engine.eventLoop.submit {
                router.dependencies.dns.flushCache()
                router.clearDecisionCache()
            }.get()
        }
        writeStatus(notify: true)
    }

    /// 休眠前落盘统计与日志簿（docs/06 §2.5）。
    public func sleep() async {
        if let engine {
            let statistics = engine.statistics
            try? await engine.eventLoop.submit { statistics.flush() }.get()
        }
        await flushPersistence()
    }

    /// 定期维护（运行中每 30 秒，平台驱动）：刷新状态快照的流量字段、写出缓冲的流量增量与日志簿、每 6 小时清理数据库。
    public func maintenance() async {
        writeStatus(notify: false, traffic: await trafficSummary())
        await flushPersistence()
        await prune()
    }

    // MARK: - 状态快照（docs/10 §3）

    /// 当前状态（含最新的流量与策略组）。
    public func refreshedStatus() async -> TunnelStatus {
        var snapshot = status
        snapshot.updatedAt = clock()
        snapshot.traffic = await trafficSummary()
        snapshot.primaryGroups = await primaryGroups()
        snapshot.network = networkSummary()
        snapshot.outboundMode = runtimeState.outboundMode
        snapshot.globalPolicy = runtimeState.globalPolicy
        snapshot.features = runtimeState.features
        return snapshot
    }

    public var state: TunnelState { status.state }

    private func trafficSummary() async -> TrafficSummary {
        guard let engine else { return TrafficSummary() }
        let statistics = engine.statistics
        return
            (try? await engine.eventLoop.submit {
                let last = statistics.recentSamples.last
                return TrafficSummary(
                    upBps: Int64(clamping: last?.up ?? 0), downBps: Int64(clamping: last?.down ?? 0),
                    sessionUpBytes: Int64(clamping: statistics.totalUp),
                    sessionDownBytes: Int64(clamping: statistics.totalDown))
            }.get()) ?? TrafficSummary()
    }

    private func primaryGroups() async -> [PolicyGroupSummary] {
        guard let engine else { return [] }
        let router = engine.router
        return
            (try? await engine.eventLoop.submit {
                let configuration = router.configuration
                return configuration.primarySelectGroups.map { group in
                    PolicyGroupSummary(
                        name: group.name,
                        current: router.dependencies.policies.selection(for: group) ?? group.members.first)
                }
            }.get()) ?? []
    }

    private func networkSummary() -> NetworkSummary {
        let snapshot = hooks.network()
        return NetworkSummary(
            interfaceType: snapshot.interfaceType.map { TrafficStatistics.interfaceName($0) }, ssid: snapshot.ssid,
            revision: snapshot.revision)
    }

    private func transition(to state: TunnelState, error: IPCError? = nil) {
        let now = clock()
        if status.state != state {
            status.since = now
        }
        status.state = state
        status.updatedAt = now
        status.lastError = error
    }

    /// 写 `State/tunnel-status.json`（原子写），按需发出状态通知。
    private func writeStatus(notify: Bool, traffic: TrafficSummary? = nil) {
        var snapshot = status
        snapshot.updatedAt = clock()
        snapshot.outboundMode = runtimeState.outboundMode
        snapshot.globalPolicy = runtimeState.globalPolicy
        snapshot.features = runtimeState.features
        snapshot.network = networkSummary()
        if let traffic {
            snapshot.traffic = traffic
            status.traffic = traffic
        }
        do {
            try JSONStateFile.write(snapshot, to: container.tunnelStatusFile)
        } catch {
            logger.error("Writing the status snapshot failed", metadata: ["error": "\(error)"])
        }
        if notify {
            hooks.notify(statusNotification)
        }
    }

    // MARK: - 持久化

    private func engineOptions(profileID: String) -> Engine.Options {
        var options = Engine.Options()
        options.httpProxy = hooks.httpProxyAddress ?? ("127.0.0.1", HTTPProxyInbound.defaultPort)
        options.systemDNSServers = hooks.systemDNSServers
        options.network = hooks.network
        options.dnsUpstreams = hooks.dnsUpstreams
        options.clock = clock
        options.logger = logger
        let selectionsURL = container.selectionsFile
        options.persistSelections = { selections in
            var file = JSONStateFile.read(SelectionsFile.self, from: selectionsURL) ?? SelectionsFile()
            file.set(selections, for: profileID)
            try? JSONStateFile.write(file, to: selectionsURL)
        }
        let buffer = trafficBuffer
        options.persistTraffic = { deltas in
            buffer.withLock { pending in
                pending.append(contentsOf: deltas)
                if pending.count > Self.trafficBufferLimit {
                    pending.removeFirst(pending.count - Self.trafficBufferLimit)
                }
            }
        }
        let logbook = self.logbook
        options.logbook = { entry in logbook?.add(entry) }
        return options
    }

    private func saveRuntimeState() {
        do {
            try JSONStateFile.write(runtimeState, to: container.runtimeStateFile)
        } catch {
            logger.error("Writing runtime.json failed", metadata: ["error": "\(error)"])
        }
    }

    /// 打开数据库；失败（`STO-002`）时隧道照常运行，只是不写统计与日志簿（docs/11 §9）。
    private func openDatabase() {
        guard database == nil else { return }
        do {
            let database = try AetherDatabase.open(directory: container.database)
            self.database = database
            logbook = LogbookWriter(database: database)
        } catch {
            logger.error("Database unavailable; statistics and logbook are disabled", metadata: ["error": "\(error)"])
        }
    }

    private func flushPersistence() async {
        await flushTraffic()
        await flushLogbook()
    }

    private func flushTraffic() async {
        let deltas = trafficBuffer.withLock { pending -> [TrafficDelta] in
            defer { pending.removeAll() }
            return pending
        }
        guard let database, !deltas.isEmpty else { return }
        do {
            try await database.mergeTraffic(deltas)
        } catch {
            logger.error("Writing traffic statistics failed", metadata: ["error": "\(error)"])
        }
    }

    private func flushLogbook() async {
        guard let logbook else { return }
        if await logbook.flush() > 0 {
            hooks.notify(logbookNotification)
        }
    }

    private func prune() async {
        let now = clock()
        guard let database, lastPrune.map({ now.timeIntervalSince($0) >= Self.pruneInterval }) ?? true else { return }
        lastPrune = now
        do {
            try await database.prune(now: now)
        } catch {
            logger.error("Database cleanup failed", metadata: ["error": "\(error)"])
        }
    }

    private func log(
        _ level: LogbookEntry.Level, _ category: LogbookEntry.Category, _ message: String,
        code: AetherErrorCode? = nil, details: String? = nil
    ) {
        switch level {
        case .info: logger.notice("\(message)")
        case .warning: logger.warning("\(message)")
        case .error: logger.error("\(message)")
        }
        logbook?.add(
            LogbookEntry(
                at: clock(), level: level, category: category, code: code?.rawValue, message: message, details: details)
        )
    }

    /// 平台层的事件写入日志与日志簿（如启用备用桥接、hev 意外退出）。
    public func record(
        _ level: LogbookEntry.Level, _ category: LogbookEntry.Category, _ message: String,
        code: AetherErrorCode? = nil
    ) async {
        log(level, category, message, code: code)
        await flushLogbook()
    }

    // MARK: - 编译

    private func resolve(_ bundle: LoadedBundle) -> ResolvedProfile {
        ProfileResolver.resolve(
            profileText: bundle.profileText, fileName: bundle.manifest.profileName,
            modules: bundle.modules.map { ModuleInput(name: $0.name, text: $0.text) })
    }

    /// 编译运行配置；有 error 级诊断时抛出首个错误的码（`CFG-…`），`details` 附诊断摘要。
    private func compile(_ bundle: LoadedBundle) throws -> RuntimeConfiguration {
        let resolved = resolve(bundle)
        guard resolved.isCommittable else {
            let errors = resolved.diagnostics.filter { $0.severity == .error }
            let summary = errors.prefix(5).map(\.description).joined(separator: "\n")
            throw IPCError(
                code: errors.first?.code ?? .ipcNoActiveBundle,
                message: "The active profile has \(errors.count) error(s)", details: ["diagnostics": summary])
        }
        return RuntimeConfiguration.compile(
            resolved, profileID: bundle.manifest.profileID, profileName: bundle.manifest.profileName)
    }

    static func summaries(_ diagnostics: [Diagnostic]) -> [DiagnosticSummary] {
        diagnostics.sorted { $0.severity > $1.severity }.prefix(ReloadResult.diagnosticLimit).map {
            DiagnosticSummary(
                code: $0.code, severity: $0.severity.rawValue, file: $0.file, line: $0.line, message: $0.message)
        }
    }
}
