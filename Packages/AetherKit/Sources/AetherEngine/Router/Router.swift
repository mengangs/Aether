import AetherDNS
import AetherFoundation
import AetherHTTP
import AetherIPC
import AetherOutbound
import AetherProfile
import AetherRules
import NIOCore
import NIOHTTP1

/// 把 `DNSService` 包装为固定用途的解析器（出站拨号用）。
public struct DNSResolverAdapter: ServerAddressResolver {
    public let dns: DNSService
    public let purpose: ResolutionPurpose

    public init(dns: DNSService, purpose: ResolutionPurpose) {
        self.dns = dns
        self.purpose = purpose
    }

    public func resolve(_ host: String, family: AddressFamily, on eventLoop: any EventLoop) -> EventLoopFuture<
        [IPAddress]
    > {
        let dns = self.dns
        let purpose = self.purpose
        return dns.eventLoop.flatSubmit {
            dns.resolve(host, type: family == .v4 ? .a : .aaaa, purpose: purpose)
        }.hop(to: eventLoop)
    }
}

/// 一次路由判定的结果（docs/06 §6 第 1–5 步）。
public struct RouteDecision: Sendable {
    public var context: RouteContext
    /// 规则模式下命中的规则；直连 / 全局模式为 nil。
    public var rule: RuleMatch?
    public var resolution: PolicyResolution
    /// 路由用 DNS 解析的耗时（毫秒）。
    public var dnsMilliseconds: Int?
}

/// 路由（docs/06 §6）：接收入站的流，确定主机名、嗅探、按出站模式与规则选择策略、执行前置检查、拨号并转发，
/// 全程更新请求记录。绑定到数据面 EventLoop：入站回调都在该 EventLoop 上调用。
public final class Router: InboundAcceptor, HTTPProxyDelegate, @unchecked Sendable {
    public struct Dependencies: Sendable {
        public var flows: FlowManager
        public var dns: DNSService
        public var rejects: RejectController
        public var requests: RequestLog
        public var policies: PolicyRegistry
        /// NAT64 支持（Apple 平台由隧道注入）。
        public var nat64: NAT64Support?
        /// 当前网络环境（SUBNET 规则、决策缓存键）。
        public var network: @Sendable () -> NetworkSnapshot
        public var timeouts: EngineTimeouts
        public var logger: Logger

        public init(
            flows: FlowManager, dns: DNSService, rejects: RejectController, requests: RequestLog,
            policies: PolicyRegistry, nat64: NAT64Support? = nil,
            network: @escaping @Sendable () -> NetworkSnapshot = { NetworkSnapshot() },
            timeouts: EngineTimeouts = .default, logger: Logger = Logger(label: "AetherEngine")
        ) {
            self.flows = flows
            self.dns = dns
            self.rejects = rejects
            self.requests = requests
            self.policies = policies
            self.nat64 = nat64
            self.network = network
            self.timeouts = timeouts
            self.logger = logger
        }
    }

    public let eventLoop: any EventLoop
    public let dependencies: Dependencies
    public let direct: DirectConnector
    let serverResolver: DNSResolverAdapter
    public private(set) var configuration: RuntimeConfiguration
    private var decisionCache = RuleDecisionCache()
    public var outboundMode: OutboundMode = .rule
    /// 全局模式使用的策略；为 nil 时取第一个非隐藏的策略组，没有策略组时为 DIRECT。
    public var globalPolicy: String?
    /// 流量回调：最终策略名、上行与下行字节数（统计聚合，docs/06 §12.1）。
    public var onTraffic: ((String, Int, Int) -> Void)?

    public init(eventLoop: any EventLoop, configuration: RuntimeConfiguration, dependencies: Dependencies) {
        self.eventLoop = eventLoop
        self.configuration = configuration
        self.dependencies = dependencies
        direct = DirectConnector(
            resolver: DNSResolverAdapter(dns: dependencies.dns, purpose: .direct), nat64: dependencies.nat64)
        serverResolver = DNSResolverAdapter(dns: dependencies.dns, purpose: .server)
    }

    /// 替换运行配置（新流使用新配置，已有流不受影响）并清空规则决策缓存（docs/06 §2.4）。
    public func replaceConfiguration(_ configuration: RuntimeConfiguration) {
        eventLoop.preconditionInEventLoop()
        self.configuration = configuration
        decisionCache = RuleDecisionCache()
    }

    /// 清空规则决策缓存（网络变化、内存压力）。
    public func clearDecisionCache() {
        eventLoop.preconditionInEventLoop()
        decisionCache.removeAll()
    }

    var flows: FlowManager { dependencies.flows }
    var dns: DNSService { dependencies.dns }
    var requests: RequestLog { dependencies.requests }

    // MARK: - 判定（第 3–5 步）

    /// 按出站模式与规则得出策略。规则需要 IP 时用 DNS 做真实解析（超时 5 秒），失败则置 `resolutionFailed` 续算。
    public func decide(_ context: RouteContext, configuration: RuntimeConfiguration) -> EventLoopFuture<RouteDecision> {
        eventLoop.preconditionInEventLoop()
        let policies = dependencies.policies
        func finish(_ context: RouteContext, rule: RuleMatch?, policy: String, dnsMilliseconds: Int?)
            -> EventLoopFuture<
                RouteDecision
            >
        {
            do {
                let resolution = try policies.resolve(policy, in: configuration)
                return eventLoop.makeSucceededFuture(
                    RouteDecision(
                        context: context, rule: rule, resolution: resolution, dnsMilliseconds: dnsMilliseconds))
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
        }
        switch outboundMode {
        case .direct:
            return finish(context, rule: nil, policy: "DIRECT", dnsMilliseconds: nil)
        case .global:
            return finish(context, rule: nil, policy: effectiveGlobalPolicy(configuration), dnsMilliseconds: nil)
        case .rule:
            switch configuration.program.evaluate(context, cache: decisionCache) {
            case .decided(let match):
                return finish(context, rule: match, policy: match.policy, dnsMilliseconds: nil)
            case .needsResolution(let host, let resume):
                let started = eventLoop.now
                let resolution = dns.resolveAll(host.value, purpose: .routing)
                let timeout = eventLoop.makePromise(of: [IPAddress].self)
                let timer = eventLoop.scheduleTask(in: dependencies.timeouts.routingResolution) {
                    timeout.fail(NetworkError(.netResolutionFailed, "Routing resolution timed out"))
                }
                resolution.whenComplete { result in
                    timer.cancel()
                    timeout.completeWith(result)
                }
                let promise = eventLoop.makePromise(of: RouteDecision.self)
                timeout.futureResult.hop(to: eventLoop).assumeIsolated().whenComplete { result in
                    var context = context
                    let dnsMilliseconds = Int((self.eventLoop.now - started).nanoseconds / 1_000_000)
                    if case .success(let addresses) = result, let address = RuleProgram.preferredAddress(addresses) {
                        context.destinationIP = address
                    } else {
                        context.resolutionFailed = true
                    }
                    let step = configuration.program.evaluate(context, from: resume)
                    // 解析之后不会再要求解析；保护性地按 DIRECT 处理。
                    let match: RuleMatch? = if case .decided(let match) = step { match } else { nil }
                    promise.completeWith(
                        finish(
                            context, rule: match, policy: match?.policy ?? "DIRECT", dnsMilliseconds: dnsMilliseconds))
                }
                return promise.futureResult
            }
        }
    }

    func effectiveGlobalPolicy(_ configuration: RuntimeConfiguration) -> String {
        if let globalPolicy, configuration.policies[globalPolicy] != nil {
            return globalPolicy
        }
        return configuration.groupOrder.first { name in
            if case .group(let group) = configuration.policies[name] { return !group.hidden }
            return false
        } ?? "DIRECT"
    }

    // MARK: - TCP（第 1–2、6–10 步）

    public func acceptTCP(_ request: InboundTCPRequest, channel: any Channel) {
        eventLoop.preconditionInEventLoop()
        handleTCP(request, channel: channel, replier: nil)
    }

    public func connect(
        _ destination: Destination, channel: any Channel, initialData: ByteBuffer?, replier: HTTPConnectReplier
    ) {
        eventLoop.preconditionInEventLoop()
        let port = channel.localAddress?.port.map { UInt16(clamping: $0) }
        let request = InboundTCPRequest(
            inbound: .httpProxy, destination: destination, inboundPort: port, initialData: initialData, replied: false)
        handleTCP(request, channel: channel, replier: replier)
    }

    private func handleTCP(_ request: InboundTCPRequest, channel: any Channel, replier: HTTPConnectReplier?) {
        let configuration = self.configuration
        let id = flows.allocateID()
        var record = RequestRecord(
            id: id.rawValue, startedAt: requests.now, inbound: Self.recordInbound(request.inbound), transport: .tcp,
            destination: request.destination.description)
        let counters = FlowCounters()
        do {
            try flows.register(id, inbound: channel, counters: counters)
        } catch {
            requests.start(record)
            requests.finish(id, error: error as? any AetherErrorProtocol)
            refuse(channel: channel, replier: replier, status: .serviceUnavailable)
            return
        }
        // 第 1 步：确定主机名。
        var context = RouteContext(
            destinationPort: request.destination.port, transport: .tcp, inbound: request.inbound,
            inboundPort: request.inboundPort, network: dependencies.network())
        var originalIP: IPAddress?
        switch request.destination {
        case .domain(let host, _):
            context.host = host
            context.hostSource = .request
        case .ip(let address, let port):
            if configuration.isDNSTarget(address, port: port), replier == nil {
                record.addNote("DNS over TCP to \(request.destination)")
                requests.start(record)
                serveDNS(channel: channel, id: id, initialData: request.initialData)
                return
            }
            if dns.isFakeIP(address) {
                guard let domain = dns.domain(forFakeIP: address), let host = Hostname(domain) else {
                    requests.start(record)
                    requests.finish(id, error: NetworkError(.netUnknownFakeIP, "No mapping for \(address)"))
                    refuse(channel: channel, replier: replier, status: .badGateway)
                    return
                }
                context.host = host
                context.hostSource = .fakeIP
            } else {
                originalIP = address
                context.destinationIP = address
                if let domain = dns.domain(forRealIP: address), let host = Hostname(domain) {
                    context.host = host
                    context.hostSource = .dnsReverse
                }
            }
        }
        record.host = context.host?.value
        record.hostSource = Self.recordHostSource(context.hostSource)
        requests.start(record)

        // 第 2 步：嗅探（TUN 上的 TCP；跳过服务器先发数据的端口）。
        let shouldSniff =
            request.inbound == .tun && configuration.general.sniffing
            && !Sniffer.skippedPorts.contains(request.destination.port)
        let sniffed: EventLoopFuture<(bytes: ByteBuffer?, result: SniffResult)>
        if shouldSniff {
            let promise = eventLoop.makePromise(of: (bytes: ByteBuffer, result: SniffResult).self)
            do {
                try channel.pipeline.syncOperations.addHandler(
                    SniffHandler(initial: request.initialData, timeout: dependencies.timeouts.sniff, promise: promise))
                sniffed = promise.futureResult.map { (Optional($0.bytes), $0.result) }
            } catch {
                sniffed = eventLoop.makeSucceededFuture((request.initialData, .unknown))
            }
        } else {
            sniffed = eventLoop.makeSucceededFuture((request.initialData, .unknown))
        }
        sniffed.hop(to: eventLoop).assumeIsolated().whenComplete { result in
            guard case .success(let (bytes, sniffResult)) = result else {
                self.requests.finish(id, error: NetworkError(.netConnectionReset, "Client closed before routing"))
                return
            }
            switch sniffResult {
            case .tls(let serverName, _):
                context.appProtocol = .https
                if context.host == nil, let serverName, let host = Hostname(serverName) {
                    context.host = host
                    context.hostSource = .sniffed
                }
            case .http(let host):
                context.appProtocol = .http
                if context.host == nil, let host, let hostname = Hostname(host) {
                    context.host = hostname
                    context.hostSource = .sniffed
                }
            default:
                break
            }
            self.requests.update(id) {
                $0.host = context.host?.value
                $0.hostSource = Self.recordHostSource(context.hostSource)
                $0.appProtocol = Self.recordAppProtocol(context.appProtocol)
            }
            self.decide(context, configuration: configuration).hop(to: self.eventLoop).assumeIsolated().whenComplete {
                outcome in
                switch outcome {
                case .failure(let error):
                    let aether = (error as? any AetherErrorProtocol) ?? NetworkError(.netPolicyUnavailable, "\(error)")
                    self.requests.finish(id, error: aether)
                    self.refuse(channel: channel, replier: replier, status: .badGateway)
                case .success(let decision):
                    self.record(decision, id: id)
                    self.forwardTCP(
                        decision, id: id, channel: channel, originalIP: originalIP, initialUpload: bytes,
                        counters: counters, replier: replier, configuration: configuration)
                }
            }
        }
    }

    /// 第 6–10 步：前置检查、拨号、转发、记录。
    private func forwardTCP(
        _ decision: RouteDecision, id: FlowID, channel: any Channel, originalIP: IPAddress?,
        initialUpload: ByteBuffer?, counters: FlowCounters, replier: HTTPConnectReplier?,
        configuration: RuntimeConfiguration
    ) {
        let context = decision.context
        let connector: any OutboundConnector
        let target: Destination
        let terminalName = decision.resolution.chain.last ?? "DIRECT"
        switch decision.resolution.terminal {
        case .reject(let kind):
            let effective = dependencies.rejects.effectiveKind(kind, host: context.host?.value)
            requests.finish(id, error: NetworkError(.netRejected, "Rejected by \(effective.rawValue)")) {
                $0.addNote(effective == kind ? effective.rawValue : "\(kind.rawValue) → \(effective.rawValue)")
            }
            if effective == .drop {
                dependencies.rejects.rejectTCP(.drop, channel: channel)
            } else if let replier {
                replier.fail(status: .forbidden)
            } else {
                dependencies.rejects.rejectTCP(effective, channel: channel)
            }
            return
        case .group:
            // PolicyRegistry 总是解析到非组策略；这里只为穷尽。
            requests.finish(id, error: NetworkError(.netPolicyUnavailable, "Unresolved group"))
            refuse(channel: channel, replier: replier, status: .badGateway)
            return
        case .direct:
            connector = direct
            if let originalIP {
                target = .ip(originalIP, port: context.destinationPort)
            } else if let host = context.host {
                target = .domain(host, port: context.destinationPort)
            } else {
                requests.finish(id, error: NetworkError(.netUnreachable, "No destination"))
                refuse(channel: channel, replier: replier, status: .badGateway)
                return
            }
        case .proxy(let node):
            guard let nodeConnector = node.connector else {
                requests.finish(
                    id, error: NetworkError(.netPolicyUnavailable, node.unavailableReason ?? "Unavailable policy"))
                refuse(channel: channel, replier: replier, status: .badGateway)
                return
            }
            connector = nodeConnector
            if let host = context.host {
                target = .domain(host, port: context.destinationPort)
            } else if let ip = context.destinationIP {
                target = .ip(ip, port: context.destinationPort)
            } else {
                requests.finish(id, error: NetworkError(.netUnreachable, "No destination"))
                refuse(channel: channel, replier: replier, status: .badGateway)
                return
            }
        }
        // 第 8 步：拨号。
        let started = eventLoop.now
        let dialContext = DialContext(
            flowID: id, eventLoop: eventLoop, deadline: started + dependencies.timeouts.handshake,
            serverResolver: serverResolver, logger: dependencies.logger)
        connector.connect(to: target, context: dialContext).hop(to: eventLoop).assumeIsolated().whenComplete { result in
            switch result {
            case .failure(let error):
                let aether = NetworkErrorMapping.map(error)
                self.requests.finish(id, error: Self.recordError(aether)) {
                    if aether is TLSError { $0.addNote("TLS \(aether.code.rawValue): \(aether.debugDetails)") }
                }
                self.refuse(channel: channel, replier: replier, status: .badGateway)
            case .success(let outbound):
                guard channel.isActive else {
                    outbound.close(promise: nil)
                    self.requests.finish(id, error: NetworkError(.netConnectionReset, "Client closed while dialing"))
                    return
                }
                self.flows.attach(id, channel: outbound)
                let connectMilliseconds = Int((self.eventLoop.now - started).nanoseconds / 1_000_000)
                self.requests.update(id) {
                    $0.remoteAddress = outbound.remoteAddress.map(Self.describe)
                    $0.timings.connect = connectMilliseconds
                }
                let onTraffic = self.onTraffic
                counters.onTransfer = { up, down in onTraffic?(terminalName, up, down) }
                let relay = {
                    do {
                        let done = try FlowRelay.glue(
                            inbound: channel, outbound: outbound, counters: counters, initialUpload: initialUpload,
                            idleTimeout: self.dependencies.timeouts.tcpIdle)
                        done.assumeIsolated().whenComplete { _ in
                            self.requests.finish(id) {
                                $0.bytesUp = counters.bytesUp
                                $0.bytesDown = counters.bytesDown
                                if let first = counters.firstDownAt {
                                    $0.timings.firstByte = Int((first - started).nanoseconds / 1_000_000)
                                }
                            }
                        }
                    } catch {
                        channel.close(promise: nil)
                        outbound.close(promise: nil)
                        self.requests.finish(id, error: NetworkError(.netConnectionReset, "\(error)"))
                    }
                }
                if let replier {
                    replier.established().assumeIsolated().whenComplete { _ in relay() }
                } else {
                    relay()
                }
            }
        }
    }

    /// TLS 握手失败在请求记录中归为 `NET-033`（TLS 码写在备注里，docs/06 §15）。
    static func recordError(_ error: any AetherErrorProtocol) -> any AetherErrorProtocol {
        if error is TLSError {
            return NetworkError(.netTLSFailed, error.debugDetails)
        }
        return error
    }

    private func record(_ decision: RouteDecision, id: FlowID) {
        requests.update(id) { record in
            record.policyChain = decision.resolution.chain
            if let rule = decision.rule {
                record.rule = RequestRecord.Rule(
                    raw: rule.rule.raw, file: rule.rule.source.file, line: rule.rule.source.line)
            } else {
                record.addNote("Outbound mode: \(self.outboundMode.rawValue)")
            }
            record.timings.dns = decision.dnsMilliseconds
            if decision.context.resolutionFailed {
                record.addNote("DNS resolution for routing failed")
            }
        }
    }

    /// 拒绝一个尚未开始转发的流：HTTP CONNECT 回复状态码，其它直接关闭。
    private func refuse(channel: any Channel, replier: HTTPConnectReplier?, status: HTTPResponseStatus) {
        if let replier {
            replier.fail(status: status)
        } else {
            channel.close(promise: nil)
        }
    }

    /// 发往 DNS 地址的 TCP 连接：交给 DNS 服务（docs/07 §2），不进入路由。
    private func serveDNS(channel: any Channel, id: FlowID, initialData: ByteBuffer?) {
        do {
            let handler = DNSStreamServerHandler(service: dns)
            try channel.pipeline.syncOperations.addHandler(handler)
            if let initialData {
                channel.pipeline.syncOperations.fireChannelRead(NIOAny(initialData))
            }
            try channel.syncOptions?.setOption(.autoRead, value: true)
            channel.closeFuture.whenComplete { _ in
                self.requests.finish(id)
            }
        } catch {
            channel.close(promise: nil)
            requests.finish(id, error: NetworkError(.netConnectionReset, "\(error)"))
        }
    }

    // MARK: - 明文 HTTP 请求（docs/06 §5.2）

    public func route(_ request: HTTPRouteRequest, channel: any Channel) -> EventLoopFuture<HTTPRouteDecision> {
        eventLoop.preconditionInEventLoop()
        let configuration = self.configuration
        let id = flows.allocateID()
        var record = RequestRecord(
            id: id.rawValue, startedAt: requests.now, inbound: .httpProxy, transport: .tcp,
            destination: request.destination.description, appProtocol: .http)
        record.method = request.method
        record.url = URLRedaction.stripQuery(request.url)
        var context = RouteContext(
            destinationPort: request.destination.port, transport: .tcp, appProtocol: .http, inbound: .httpProxy,
            inboundPort: request.inboundPort, url: request.url, userAgent: request.userAgent,
            network: dependencies.network())
        switch request.destination {
        case .domain(let host, _):
            context.host = host
            context.hostSource = .request
        case .ip(let address, _):
            context.destinationIP = address
        }
        record.host = context.host?.value
        record.hostSource = Self.recordHostSource(context.hostSource)
        requests.start(record)
        let observer = RequestObserver(router: self, id: id)
        return decide(context, configuration: configuration).flatMapError { error in
            observer.fail(error)
            return self.eventLoop.makeFailedFuture(error)
        }.map { decision -> HTTPRouteDecision in
            self.record(decision, id: id)
            let terminalName = decision.resolution.chain.last ?? "DIRECT"
            observer.policyName = terminalName
            switch decision.resolution.terminal {
            case .reject(let kind):
                let effective = self.dependencies.rejects.effectiveKind(kind, host: decision.context.host?.value)
                observer.rejection = effective
                return .reject(
                    self.dependencies.rejects.httpResponse(
                        for: effective, errorPage: configuration.general.showErrorPageForReject),
                    observer: observer)
            case .group:
                return .fail(NetworkError(.netPolicyUnavailable, "Unresolved group"), observer: observer)
            case .direct:
                let target = request.destination
                let direct = self.direct
                let dialContext = self.dialContext(for: id)
                return .forward(
                    HTTPForwardPlan(
                        reuseKey: "DIRECT|\(target)", dial: { direct.connect(to: target, context: dialContext) },
                        observer: observer))
            case .proxy(let node):
                guard let connector = node.connector else {
                    return .fail(
                        NetworkError(.netPolicyUnavailable, node.unavailableReason ?? "Unavailable policy"),
                        observer: observer)
                }
                let target = request.destination
                let dialContext = self.dialContext(for: id)
                return .forward(
                    HTTPForwardPlan(
                        reuseKey: "\(node.identity)|\(target)",
                        dial: { connector.connect(to: target, context: dialContext) }, observer: observer))
            }
        }
    }

    private func dialContext(for id: FlowID) -> DialContext {
        DialContext(
            flowID: id, eventLoop: eventLoop, deadline: eventLoop.now + dependencies.timeouts.handshake,
            serverResolver: serverResolver, logger: dependencies.logger)
    }

    // MARK: - UDP（docs/06 §10）

    /// 同时存在的 UDP 关联上限（docs/06 §13）；超出时新关联立即关闭（`NET-040`，写日志）。
    public var udpAssociationLimit = 512
    private var udpSessions: [ObjectIdentifier: UDPSession] = [:]

    /// 当前的 UDP 关联数。
    public var udpAssociationCount: Int { udpSessions.count }

    public func acceptUDP(_ association: SOCKS5UDPAssociation) {
        acceptUDP(client: association)
    }

    /// 接管一个入站 UDP 关联：建立它的 NAT 表（`UDPSession`）。
    func acceptUDP(client: any InboundUDPClient, settings: UDPSession.Settings? = nil) {
        eventLoop.preconditionInEventLoop()
        guard udpSessions.count < udpAssociationLimit else {
            dependencies.logger.warning(
                "\(NetworkError(.netTooManyFlows, "UDP association limit \(udpAssociationLimit) reached"))")
            client.close()
            return
        }
        var resolvedSettings = settings ?? UDPSession.Settings()
        if settings == nil {
            resolvedSettings.flowIdle = dependencies.timeouts.udpIdle
            resolvedSettings.idle = dependencies.timeouts.udpIdle
            resolvedSettings.dnsIdle = dependencies.timeouts.dnsUDPIdle
        }
        let dns = self.dns
        let hooks = UDPSession.Hooks(
            isDNSTarget: { [unowned self] destination in
                guard case .ip(let address, let port) = destination else { return false }
                return self.configuration.isDNSTarget(address, port: port)
            },
            answerDNS: { payload in
                dns.answer(Array(payload.readableBytesView), transport: .udp).map { $0.map { ByteBuffer(bytes: $0) } }
            },
            route: { [unowned self] destination, payload, id in
                self.routeUDP(destination, firstPayload: payload, id: id, configuration: self.configuration)
            },
            allocateID: { [unowned self] in self.flows.allocateID() },
            onTraffic: onTraffic)
        let session = UDPSession(
            client: client, eventLoop: eventLoop, requests: requests, settings: resolvedSettings, hooks: hooks)
        let key = ObjectIdentifier(session)
        udpSessions[key] = session
        session.onClosed = { [weak self] in
            self?.udpSessions[key] = nil
        }
        session.start()
    }

    /// 关闭全部 UDP 关联（停止隧道）。
    public func closeUDPAssociations() {
        eventLoop.preconditionInEventLoop()
        for session in Array(udpSessions.values) {
            session.close()
        }
    }

    /// 一个 UDP 流的路由（docs/06 §6 第 1、3–6 步与 §10）：主机名恢复、出站模式与规则、策略解析、前置检查
    /// （block-quic、`udp-policy-not-supported-behaviour`、拒绝），得到丢弃或转发。
    func routeUDP(
        _ destination: Destination, firstPayload: ByteBuffer, id: FlowID, configuration: RuntimeConfiguration
    ) -> EventLoopFuture<UDPRoute> {
        var context = RouteContext(
            destinationPort: destination.port, transport: .udp, inbound: .tun, inboundPort: nil,
            network: dependencies.network())
        var originalIP: IPAddress?
        switch destination {
        case .domain(let host, _):
            context.host = host
            context.hostSource = .request
        case .ip(let address, _):
            if dns.isFakeIP(address) {
                guard let domain = dns.domain(forFakeIP: address), let host = Hostname(domain) else {
                    return eventLoop.makeSucceededFuture(
                        .drop(NetworkError(.netUnknownFakeIP, "No mapping for \(address)")))
                }
                context.host = host
                context.hostSource = .fakeIP
            } else {
                originalIP = address
                context.destinationIP = address
                if let domain = dns.domain(forRealIP: address), let host = Hostname(domain) {
                    context.host = host
                    context.hostSource = .dnsReverse
                }
            }
        }
        if destination.port == 443, Sniffer.isQUICLongHeader(firstPayload) {
            context.appProtocol = .quic
        }
        requests.update(id) {
            $0.host = context.host?.value
            $0.hostSource = Self.recordHostSource(context.hostSource)
            $0.appProtocol = Self.recordAppProtocol(context.appProtocol)
        }
        return decide(context, configuration: configuration).hop(to: eventLoop).assumeIsolated().flatMap {
            decision -> EventLoopFuture<UDPRoute> in
            self.record(decision, id: id)
            return self.udpRoute(
                decision, id: id, originalIP: originalIP, configuration: configuration)
        }.nonisolated()
    }

    /// 第 6 步（前置检查）与出站目标。
    private func udpRoute(
        _ decision: RouteDecision, id: FlowID, originalIP: IPAddress?, configuration: RuntimeConfiguration
    ) -> EventLoopFuture<UDPRoute> {
        let context = decision.context
        let port = context.destinationPort
        let terminalName = decision.resolution.chain.last ?? "DIRECT"
        var node: ProxyNode?
        if case .proxy(let proxy) = decision.resolution.terminal {
            node = proxy
        }
        let supportsUDP: Bool
        switch decision.resolution.terminal {
        case .direct: supportsUDP = true
        case .proxy(let proxy): supportsUDP = proxy.connector != nil && proxy.supportsUDP
        case .reject, .group: supportsUDP = false
        }
        // block-quic：节点的设置优先于全局设置（docs/04）。
        if port == 443, !decision.resolution.terminal.isReject {
            let mode = Self.blockQUICMode(node: node, general: configuration.general.blockQUIC)
            if mode == .always || (mode == .auto && !supportsUDP) {
                requests.update(id) { $0.addNote("block-quic") }
                return eventLoop.makeSucceededFuture(.drop(NetworkError(.netRejected, "QUIC blocked")))
            }
        }
        switch decision.resolution.terminal {
        case .reject(let kind):
            requests.update(id) { $0.addNote(kind.rawValue) }
            return eventLoop.makeSucceededFuture(.drop(NetworkError(.netRejected, "Rejected by \(kind.rawValue)")))
        case .group:
            return eventLoop.makeSucceededFuture(.drop(NetworkError(.netPolicyUnavailable, "Unresolved group")))
        case .direct:
            return directUDPRoute(context: context, originalIP: originalIP, policy: terminalName, id: id)
        case .proxy(let proxy):
            guard let connector = proxy.connector else {
                return eventLoop.makeSucceededFuture(
                    .drop(NetworkError(.netPolicyUnavailable, proxy.unavailableReason ?? "Unavailable policy")))
            }
            guard proxy.supportsUDP else {
                if configuration.general.udpPolicyNotSupportedBehaviour.uppercased() == "DIRECT" {
                    requests.update(id) { $0.addNote("\(proxy.name) does not relay UDP; using DIRECT") }
                    return directUDPRoute(context: context, originalIP: originalIP, policy: "DIRECT", id: id)
                }
                return eventLoop.makeSucceededFuture(
                    .drop(NetworkError(.netPolicyNoUDP, "\(proxy.name) does not relay UDP")))
            }
            let target: Destination
            if let host = context.host {
                target = .domain(host, port: port)
            } else if let ip = context.destinationIP {
                target = .ip(ip, port: port)
            } else {
                return eventLoop.makeSucceededFuture(.drop(NetworkError(.netUnreachable, "No destination")))
            }
            let dialContext = self.dialContext(for: id)
            return eventLoop.makeSucceededFuture(
                .forward(
                    key: "proxy|\(proxy.identity)", policy: terminalName, target: target,
                    open: { connector.openUDP(context: dialContext) }))
        }
    }

    /// DIRECT：原始目标是真实 IP 时直接发往它；否则在本地按域名解析（遵守 `[Host]`），发往首个 IPv4（没有则
    /// IPv6），使回包能按地址准确归属。
    private func directUDPRoute(context: RouteContext, originalIP: IPAddress?, policy: String, id: FlowID)
        -> EventLoopFuture<UDPRoute>
    {
        let port = context.destinationPort
        let direct = self.direct
        let dialContext = self.dialContext(for: id)
        let route: @Sendable (IPAddress) -> UDPRoute = { address in
            .forward(
                key: "direct", policy: policy, target: .ip(address, port: port),
                open: { direct.openUDP(context: dialContext) })
        }
        if let originalIP {
            return eventLoop.makeSucceededFuture(route(originalIP))
        }
        guard let host = context.host else {
            return eventLoop.makeSucceededFuture(.drop(NetworkError(.netUnreachable, "No destination")))
        }
        return dns.resolveAll(host.value, purpose: .direct).map { addresses -> UDPRoute in
            guard let address = RuleProgram.preferredAddress(addresses) else {
                return .drop(NetworkError(.netResolutionFailed, "No address for \(host.value)"))
            }
            return route(address)
        }.recover { error in
            .drop(NetworkError(.netResolutionFailed, "\(host.value): \(error)"))
        }
    }

    static func blockQUICMode(node: ProxyNode?, general: GeneralSettings.BlockQUIC) -> GeneralSettings.BlockQUIC {
        switch node?.blockQUIC {
        case "on": return .always
        case "off": return .never
        case "auto": return .auto
        default: return general
        }
    }

    // MARK: - 记录字段转换

    static func recordInbound(_ inbound: RouteContext.InboundKind) -> RequestRecord.Inbound {
        switch inbound {
        case .tun: return .tun
        case .httpProxy: return .httpProxy
        case .socks: return .socks
        case .script(let name): return .script(name)
        }
    }

    static func recordHostSource(_ source: RouteContext.HostSource) -> RequestRecord.HostSource {
        switch source {
        case .request: return .request
        case .fakeIP: return .fakeIP
        case .dnsReverse: return .dnsReverse
        case .sniffed: return .sniffed
        case .none: return .none
        }
    }

    static func recordAppProtocol(_ value: RouteContext.AppProtocol) -> RequestRecord.AppProtocol {
        switch value {
        case .unknown: return .unknown
        case .http: return .http
        case .https: return .https
        case .quic: return .quic
        }
    }

    static func describe(_ address: SocketAddress) -> String {
        guard let ip = address.ipAddress, let port = address.port else { return "\(address)" }
        return address.protocol == .inet6 ? "[\(ip)]:\(port)" : "\(ip):\(port)"
    }
}

/// 明文 HTTP 请求的记录观察者。
final class RequestObserver: HTTPExchangeObserver, @unchecked Sendable {
    private weak var router: Router?
    private let id: FlowID
    private let started: NIODeadline
    var policyName = "DIRECT"
    var rejection: RejectKind?
    private var up: UInt64 = 0
    private var down: UInt64 = 0
    private var finished = false

    init(router: Router, id: FlowID) {
        self.router = router
        self.id = id
        started = router.eventLoop.now
    }

    func upstreamConnected(remoteAddress: String?) {
        guard let router else { return }
        let elapsed = Int((router.eventLoop.now - started).nanoseconds / 1_000_000)
        router.requests.update(id) {
            $0.remoteAddress = remoteAddress
            $0.timings.connect = elapsed
        }
    }

    func responseStarted(status: Int) {
        guard let router else { return }
        let elapsed = Int((router.eventLoop.now - started).nanoseconds / 1_000_000)
        router.requests.update(id) {
            $0.statusCode = status
            $0.timings.firstByte = elapsed
        }
    }

    func transferred(up: Int, down: Int) {
        self.up &+= UInt64(up)
        self.down &+= UInt64(down)
        router?.onTraffic?(policyName, up, down)
    }

    func finished(error: (any AetherErrorProtocol)?) {
        guard !finished, let router else { return }
        finished = true
        let failure: (any AetherErrorProtocol)? =
            error.map(Router.recordError) ?? rejection.map { NetworkError(.netRejected, "Rejected by \($0.rawValue)") }
        router.requests.finish(id, error: failure) { record in
            record.bytesUp = self.up
            record.bytesDown = self.down
            if let rejection = self.rejection {
                record.addNote(rejection.rawValue)
            }
        }
    }

    func fail(_ error: any Error) {
        finished(error: (error as? any AetherErrorProtocol) ?? NetworkError(.netPolicyUnavailable, "\(error)"))
    }
}
