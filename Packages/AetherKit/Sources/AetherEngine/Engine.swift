import AetherDNS
import AetherFoundation
import AetherIPC
import AetherOutbound
import AetherRules
import NIOCore
import NIOPosix

/// 引擎（平台无关部分，docs/06 §1–§2、§14）：持有执行环境、DNS、路由与入站，支持运行配置热替换。
/// 隧道（`AetherTunnelSupport`）与 `aether-cli run` 都通过它运行同一套数据面。
///
/// 控制面方法（`start`、`reload`、`stop`、选择与模式）是 async 的，内部切到数据面 EventLoop 执行；可从任意并发上下文调用。
public final class Engine: Sendable {
    public struct Options: Sendable {
        /// 内部 SOCKS5 入站监听地址；端口 0 表示系统分配（隧道内部入站）。
        public var socksHost = "127.0.0.1"
        public var socksPort = 0
        /// 为 nil 时不要求认证（`aether-cli run`）；隧道使用每次启动随机生成的凭据。
        public var socksCredentials: SOCKS5Credentials? = .random()
        /// HTTP 代理入站；为 nil 时不启动（`system-proxy = false`）。
        public var httpProxy: (host: String, port: Int)? = ("127.0.0.1", HTTPProxyInbound.defaultPort)
        /// 系统 DNS 服务器（docs/07 §4.1）。
        public var systemDNSServers: @Sendable () -> [IPAddress] = { [] }
        public var nat64: NAT64Support?
        public var network: @Sendable () -> NetworkSnapshot = { NetworkSnapshot() }
        /// 选择变化时调用，参数为当前配置的全部选择（隧道写入 `State/selections.json`）。
        public var persistSelections: (@Sendable ([String: String]) -> Void)?
        public var timeouts = EngineTimeouts.default
        public var logger = Logger(label: "AetherEngine")
        /// 测试用：按写法构造 DNS 上游（为 nil 时使用真实上游）。
        public var dnsUpstreams: (@Sendable (DNSUpstreamSpec) -> (any DNSUpstream)?)?

        public init() {}
    }

    public let threads: EngineThreads
    public let router: Router
    public let socks: SOCKS5Inbound
    private let httpProxy: Locked<HTTPProxyInbound?>
    public let options: Options

    private init(
        threads: EngineThreads, router: Router, socks: SOCKS5Inbound, httpProxy: HTTPProxyInbound?, options: Options
    ) {
        self.threads = threads
        self.router = router
        self.socks = socks
        self.httpProxy = Locked(httpProxy)
        self.options = options
    }

    public var eventLoop: any EventLoop { router.eventLoop }
    public var dns: DNSService { router.dependencies.dns }
    public var policies: PolicyRegistry { router.dependencies.policies }
    public var requests: RequestLog { router.dependencies.requests }

    /// 当前 HTTP 代理入站（未启动时为 nil）。
    public var httpProxyInbound: HTTPProxyInbound? { httpProxy.current }

    /// 启动：DNS 服务、路由、内部 SOCKS5 入站与（按需）HTTP 代理入站（docs/06 §2.2 第 5 步）。
    public static func start(
        configuration: RuntimeConfiguration, options: Options = Options(), selections: [String: String] = [:],
        threads: EngineThreads = EngineThreads()
    ) async throws -> Engine {
        let loop = threads.eventLoop
        let router = try await loop.submit { () -> Router in
            let dns = DNSService(
                configuration: configuration.dns,
                environment: .init(
                    eventLoop: loop, blockingPool: threads.blockingPool, systemServers: options.systemDNSServers,
                    logger: options.logger, makeUpstream: options.dnsUpstreams))
            let policies = PolicyRegistry(selections: selections)
            policies.migrate(to: configuration)
            let dependencies = Router.Dependencies(
                flows: FlowManager(eventLoop: loop), dns: dns, rejects: RejectController(eventLoop: loop),
                requests: RequestLog(eventLoop: loop), policies: policies, nat64: options.nat64,
                network: options.network, timeouts: options.timeouts, logger: options.logger)
            return Router(eventLoop: loop, configuration: configuration, dependencies: dependencies)
        }.get()
        let socks: SOCKS5Inbound
        var http: HTTPProxyInbound?
        do {
            socks = try await SOCKS5Inbound.start(
                on: loop, host: options.socksHost, port: options.socksPort, credentials: options.socksCredentials,
                acceptor: router
            ).get()
            if let address = options.httpProxy, configuration.general.systemProxy {
                http = try await HTTPProxyInbound.start(
                    on: loop, host: address.host, port: address.port, delegate: router,
                    keepAliveTimeout: options.timeouts.httpKeepAlive
                ).get()
            }
        } catch {
            try? await threads.shutdown()
            throw error
        }
        for note in configuration.notes {
            options.logger.notice("\(note)")
        }
        return Engine(threads: threads, router: router, socks: socks, httpProxy: http, options: options)
    }

    /// 热替换运行配置（docs/06 §2.4 第 3–5 步）：新流使用新配置，已有流保持旧配置直到结束；策略组选择按同名迁移；
    /// 清空规则决策缓存；DNS 只替换 Host 表与上游（缓存保持）。`system-proxy` 变化时启停 HTTP 代理入站。
    public func reload(_ configuration: RuntimeConfiguration) async throws {
        let router = self.router
        try await eventLoop.submit {
            router.replaceConfiguration(configuration)
            router.dependencies.dns.update(configuration: configuration.dns)
            router.dependencies.policies.migrate(to: configuration)
        }.get()
        let wantsHTTP = configuration.general.systemProxy && options.httpProxy != nil
        if wantsHTTP, httpProxy.current == nil, let address = options.httpProxy {
            let inbound = try await HTTPProxyInbound.start(
                on: eventLoop, host: address.host, port: address.port, delegate: router,
                keepAliveTimeout: options.timeouts.httpKeepAlive
            ).get()
            httpProxy.withLock { $0 = inbound }
        } else if !wantsHTTP, let inbound = takeHTTPProxy() {
            try? await inbound.close().get()
        }
        for note in configuration.notes {
            options.logger.notice("\(note)")
        }
        persist()
    }

    /// 选择 `select` 组的成员并持久化。组或成员不存在时抛 `IPC-011`。
    public func selectPolicy(group: String, member: String) async throws {
        let router = self.router
        try await eventLoop.submit {
            guard case .group(let policyGroup) = router.configuration.policies[group] else {
                throw IPCError(code: .ipcInvalidArgument, message: "No policy group named \(group)")
            }
            do {
                try router.dependencies.policies.select(member, in: policyGroup)
            } catch {
                throw IPCError(code: .ipcInvalidArgument, message: "\(member) cannot be selected in \(group)")
            }
        }.get()
        persist()
    }

    public func setOutboundMode(_ mode: OutboundMode) async throws {
        let router = self.router
        try await eventLoop.submit { router.outboundMode = mode }.get()
    }

    /// 设置全局模式的策略；不存在时抛 `IPC-011`。
    public func setGlobalPolicy(_ name: String) async throws {
        let router = self.router
        try await eventLoop.submit {
            guard router.configuration.policies[name] != nil else {
                throw IPCError(code: .ipcInvalidArgument, message: "No policy named \(name)")
            }
            router.globalPolicy = name
        }.get()
    }

    /// 取出并清空当前的 HTTP 代理入站。
    private func takeHTTPProxy() -> HTTPProxyInbound? {
        httpProxy.withLock { current in
            defer { current = nil }
            return current
        }
    }

    private func persist() {
        options.persistSelections?(policies.currentSelections)
    }

    /// 停止（docs/06 §2.3 第 1、3、5 步）：停止接受新连接，关闭 UDP 关联，半关闭全部 TCP 流并在宽限期后强制关闭，
    /// 关闭执行环境。
    public func stop() async {
        try? await socks.close().get()
        if let inbound = takeHTTPProxy() {
            try? await inbound.close().get()
        }
        let router = self.router
        let grace = options.timeouts.stopGrace
        _ = try? await eventLoop.flatSubmit {
            router.closeUDPAssociations()
            return router.dependencies.flows.closeAll(grace: grace)
        }.get()
        try? await threads.shutdown()
    }
}
