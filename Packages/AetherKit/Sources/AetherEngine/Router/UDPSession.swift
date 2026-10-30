import AetherFoundation
import AetherIPC
import AetherOutbound
import NIOCore

/// 入站 UDP 关联的客户端一侧（SOCKS5 `UDP ASSOCIATE`）。绑定到数据面 EventLoop。
public protocol InboundUDPClient: AnyObject {
    /// 收到客户端发往 `Destination` 的载荷。
    var onDatagram: ((Destination, ByteBuffer) -> Void)? { get set }
    /// 关联结束时回调一次。
    var onClose: (() -> Void)? { get set }
    /// 把来自 `source` 的载荷发回客户端。
    func send(_ payload: ByteBuffer, from source: Destination)
    /// 结束关联（重复调用无副作用）。
    func close()
}

extension SOCKS5UDPAssociation: InboundUDPClient {}

/// 一个 UDP 流（关联内的一个目标）的路由结果（docs/06 §10）。
enum UDPRoute: Sendable {
    /// 丢弃发往该目标的数据报（拒绝、策略不支持 UDP、block-quic、未知 Fake IP、解析失败）。
    case drop(any AetherErrorProtocol)
    /// 经出站关联转发。`key` 相同的流共享一个出站关联（同一策略）；`target` 是交给出站关联的目标；
    /// `policy` 是最终策略名（流量统计）。
    case forward(
        key: String, policy: String, target: Destination,
        open: @Sendable () -> EventLoopFuture<any OutboundUDPAssociation>)
}

/// 一个入站 UDP 关联的 NAT 表（docs/06 §10）。绑定到数据面 EventLoop，所有方法都在该 EventLoop 上调用。
///
/// - 发往 DNS 地址（或命中 `hijack-dns`）的数据报交给 DNS 服务，不进入路由，也不建流。
/// - 其它每个新目标是一个 UDP 流：独立路由，结果缓存在表内；流数上限 `flowLimit`，超出时结束最久未活动的流。
/// - 同一策略的流共享一个出站关联；出站关联关闭时使用它的流随之结束，之后的数据报重新路由。
/// - 回包按"出站目标 → 客户端看到的目标"反查（客户端发往 Fake IP 时，回包以 Fake IP 为来源）；查不到时，
///   若该出站关联上只有一个（或多个，取最近活动的）同端口的域名目标流则归于它，否则来源是 IP 时原样转发
///   （完全锥形 NAT 行为），其余丢弃。
/// - 路由或建立出站关联期间的数据报进入关联级待发队列，上限 `pendingLimit` 包，超出时丢弃最旧的。
/// - 被丢弃的目标（拒绝、失败）在 `retryAfter` 之后的下一个数据报重新路由。
/// - 空闲：流在 `flowIdle` 内无数据即结束；整个关联在空闲超时（只有 DNS 数据报时 `dnsIdle`，否则 `idle`）后关闭。
final class UDPSession: @unchecked Sendable {
    struct Settings {
        var flowLimit = 256
        var pendingLimit = 32
        var outboundLimit = 32
        var flowIdle: TimeAmount = .seconds(60)
        var idle: TimeAmount = .seconds(60)
        var dnsIdle: TimeAmount = .seconds(10)
        var retryAfter: TimeAmount = .seconds(10)
    }

    struct Hooks {
        var isDNSTarget: (Destination) -> Bool
        var answerDNS: (ByteBuffer) -> EventLoopFuture<ByteBuffer?>
        /// 新流的路由（第一个数据报用于识别 QUIC）。由路由更新请求记录中的主机、规则与策略链。
        var route: (Destination, ByteBuffer, FlowID) -> EventLoopFuture<UDPRoute>
        var allocateID: () -> FlowID
        /// 流量回调：最终策略名、上行与下行字节数。
        var onTraffic: ((String, Int, Int) -> Void)?
    }

    private final class Flow {
        enum State {
            case routing
            case forwarding(key: String, target: Destination)
            case dropped(until: NIODeadline)
        }

        let id: FlowID
        let destination: Destination
        var state = State.routing
        var policy: String?
        var lastActivity: NIODeadline
        var bytesUp = 0
        var bytesDown = 0

        init(id: FlowID, destination: Destination, now: NIODeadline) {
            self.id = id
            self.destination = destination
            lastActivity = now
        }
    }

    private final class Outbound {
        var association: (any OutboundUDPAssociation)?
        /// 使用它的流（客户端看到的目标）。
        var flows: Set<Destination> = []
        /// 出站目标 → 客户端看到的目标。
        var targets: [Destination: Destination] = [:]
    }

    let eventLoop: any EventLoop
    let client: any InboundUDPClient
    private let requests: RequestLog
    private let settings: Settings
    private let hooks: Hooks
    private var flows: [Destination: Flow] = [:]
    private var outbounds: [String: Outbound] = [:]
    /// 等待路由或出站关联的数据报（目标、载荷），上限 `pendingLimit`。
    private var pending = CircularBuffer<(Destination, ByteBuffer)>()
    private var lastActivity: NIODeadline
    private var carriesNonDNS = false
    private var timer: Scheduled<Void>?
    private var closed = false
    /// 丢弃的数据报数（待发队列溢出、目标被丢弃、无法归属的回包）。
    private(set) var droppedDatagrams = 0
    /// 关联结束时回调一次。
    var onClosed: (() -> Void)?

    init(client: any InboundUDPClient, eventLoop: any EventLoop, requests: RequestLog, settings: Settings, hooks: Hooks)
    {
        self.client = client
        self.eventLoop = eventLoop
        self.requests = requests
        self.settings = settings
        self.hooks = hooks
        lastActivity = eventLoop.now
    }

    var flowCount: Int { flows.count }
    var outboundCount: Int { outbounds.count }

    func start() {
        eventLoop.preconditionInEventLoop()
        client.onDatagram = { [weak self] destination, payload in
            self?.received(payload, to: destination)
        }
        client.onClose = { [weak self] in
            self?.close()
        }
        schedule(at: lastActivity + settings.dnsIdle)
    }

    // MARK: - 客户端 → 出站

    private func received(_ payload: ByteBuffer, to destination: Destination) {
        guard !closed else { return }
        let now = eventLoop.now
        lastActivity = now
        if hooks.isDNSTarget(destination) {
            hooks.answerDNS(payload).hop(to: eventLoop).assumeIsolated().whenSuccess { response in
                if let response, !self.closed {
                    self.client.send(response, from: destination)
                }
            }
            return
        }
        carriesNonDNS = true
        if let flow = flows[destination] {
            flow.lastActivity = now
            switch flow.state {
            case .routing:
                enqueue(payload, for: destination)
            case .forwarding(let key, let target):
                if let association = outbounds[key]?.association {
                    send(payload, flow: flow, target: target, association: association)
                } else {
                    enqueue(payload, for: destination)
                }
            case .dropped(let until):
                if now >= until {
                    flows[destination] = nil
                    startFlow(destination, payload: payload, now: now)
                } else {
                    droppedDatagrams += 1
                }
            }
            return
        }
        startFlow(destination, payload: payload, now: now)
    }

    private func startFlow(_ destination: Destination, payload: ByteBuffer, now: NIODeadline) {
        if flows.count >= settings.flowLimit, let oldest = flows.values.min(by: { $0.lastActivity < $1.lastActivity }) {
            finish(oldest, error: nil)
        }
        let id = hooks.allocateID()
        let flow = Flow(id: id, destination: destination, now: now)
        flows[destination] = flow
        requests.start(
            RequestRecord(
                id: id.rawValue, startedAt: requests.now, inbound: .tun, transport: .udp,
                destination: destination.description))
        enqueue(payload, for: destination)
        hooks.route(destination, payload, id).hop(to: eventLoop).assumeIsolated().whenComplete { result in
            guard !self.closed, let current = self.flows[destination], current === flow else { return }
            switch result {
            case .failure(let error):
                self.drop(flow, error: (error as? any AetherErrorProtocol) ?? NetworkError(.netUnreachable, "\(error)"))
            case .success(.drop(let error)):
                self.drop(flow, error: error)
            case .success(.forward(let key, let policy, let target, let open)):
                self.forward(flow, key: key, policy: policy, target: target, open: open)
            }
        }
    }

    private func drop(_ flow: Flow, error: any AetherErrorProtocol) {
        flow.state = .dropped(until: eventLoop.now + settings.retryAfter)
        discardPending(for: flow.destination)
        requests.finish(flow.id, error: error)
    }

    private func forward(
        _ flow: Flow, key: String, policy: String, target: Destination,
        open: () -> EventLoopFuture<any OutboundUDPAssociation>
    ) {
        flow.state = .forwarding(key: key, target: target)
        flow.policy = policy
        requests.update(flow.id) { $0.remoteAddress = target.description }
        if let outbound = outbounds[key] {
            outbound.flows.insert(flow.destination)
            outbound.targets[target] = flow.destination
            if outbound.association != nil {
                flushPending(key: key)
            }
            return
        }
        guard outbounds.count < settings.outboundLimit else {
            drop(flow, error: NetworkError(.netTooManyFlows, "Too many outbound UDP associations"))
            return
        }
        let outbound = Outbound()
        outbound.flows.insert(flow.destination)
        outbound.targets[target] = flow.destination
        outbounds[key] = outbound
        open().hop(to: eventLoop).assumeIsolated().whenComplete { result in
            guard self.outbounds[key] === outbound else {
                if case .success(let association) = result { association.close() }
                return
            }
            switch result {
            case .failure(let error):
                self.outbounds[key] = nil
                let aether = NetworkErrorMapping.map(error)
                for destination in outbound.flows {
                    if let flow = self.flows[destination] {
                        self.drop(flow, error: Router.recordError(aether))
                    }
                }
            case .success(let association):
                guard !self.closed else {
                    association.close()
                    return
                }
                outbound.association = association
                association.onDatagram = { [weak self] payload, source in
                    self?.receivedFromOutbound(payload, source: source, key: key)
                }
                association.closeFuture.hop(to: self.eventLoop).assumeIsolated().whenComplete { _ in
                    self.outboundClosed(key: key, outbound: outbound)
                }
                self.flushPending(key: key)
            }
        }
    }

    private func send(
        _ payload: ByteBuffer, flow: Flow, target: Destination, association: any OutboundUDPAssociation
    ) {
        let count = payload.readableBytes
        flow.bytesUp += count
        association.send(payload, to: target)
        if let policy = flow.policy {
            hooks.onTraffic?(policy, count, 0)
        }
    }

    private func enqueue(_ payload: ByteBuffer, for destination: Destination) {
        if pending.count >= settings.pendingLimit {
            pending.removeFirst()
            droppedDatagrams += 1
        }
        pending.append((destination, payload))
    }

    private func discardPending(for destination: Destination) {
        let before = pending.count
        pending = CircularBuffer(pending.filter { $0.0 != destination })
        droppedDatagrams += before - pending.count
    }

    /// 把等待中、已可发送的数据报按到达顺序发出。
    private func flushPending(key: String) {
        guard let association = outbounds[key]?.association, !pending.isEmpty else { return }
        var remaining = CircularBuffer<(Destination, ByteBuffer)>()
        for (destination, payload) in pending {
            if let flow = flows[destination], case .forwarding(let flowKey, let target) = flow.state, flowKey == key {
                send(payload, flow: flow, target: target, association: association)
            } else {
                remaining.append((destination, payload))
            }
        }
        pending = remaining
    }

    // MARK: - 出站 → 客户端

    private func receivedFromOutbound(_ payload: ByteBuffer, source: Destination, key: String) {
        guard !closed, let outbound = outbounds[key] else { return }
        let now = eventLoop.now
        let destination: Destination
        if let mapped = outbound.targets[source] {
            destination = mapped
        } else if let guess = guessDestination(source: source, outbound: outbound) {
            destination = guess
        } else if case .ip = source {
            destination = source
        } else {
            droppedDatagrams += 1
            return
        }
        lastActivity = now
        if let flow = flows[destination] {
            flow.lastActivity = now
            flow.bytesDown += payload.readableBytes
            if let policy = flow.policy {
                hooks.onTraffic?(policy, 0, payload.readableBytes)
            }
        }
        client.send(payload, from: destination)
    }

    /// 服务器以解析后的 IP 回包、而流的出站目标是域名时：同端口的域名目标流中最近活动的那个。
    private func guessDestination(source: Destination, outbound: Outbound) -> Destination? {
        var best: Flow?
        for (target, destination) in outbound.targets {
            guard case .domain = target, target.port == source.port, let flow = flows[destination] else { continue }
            if best.map({ flow.lastActivity > $0.lastActivity }) ?? true {
                best = flow
            }
        }
        return best?.destination
    }

    private func outboundClosed(key: String, outbound: Outbound) {
        guard outbounds[key] === outbound else { return }
        outbounds[key] = nil
        for destination in outbound.flows {
            if let flow = flows[destination] {
                finish(flow, error: nil)
            }
        }
    }

    // MARK: - 回收

    private func finish(_ flow: Flow, error: (any AetherErrorProtocol)?) {
        flows[flow.destination] = nil
        discardPending(for: flow.destination)
        if case .forwarding(let key, let target) = flow.state, let outbound = outbounds[key] {
            outbound.flows.remove(flow.destination)
            outbound.targets[target] = nil
            if outbound.flows.isEmpty {
                outbounds[key] = nil
                outbound.association?.close()
            }
        }
        if case .dropped = flow.state { return }
        requests.finish(flow.id, error: error) {
            $0.bytesUp = UInt64(flow.bytesUp)
            $0.bytesDown = UInt64(flow.bytesDown)
        }
    }

    private func schedule(at deadline: NIODeadline) {
        timer?.cancel()
        timer = eventLoop.assumeIsolated().scheduleTask(deadline: deadline) {
            self.sweep()
        }
    }

    /// 结束空闲的流与过期的丢弃记录；整个关联空闲超时则关闭，否则在下一个到期时间再检查。
    func sweep() {
        guard !closed else { return }
        let now = eventLoop.now
        let associationTimeout = carriesNonDNS ? settings.idle : settings.dnsIdle
        if now - lastActivity >= associationTimeout {
            close()
            return
        }
        var next = lastActivity + associationTimeout
        for flow in Array(flows.values) {
            switch flow.state {
            case .dropped(let until):
                if now >= until {
                    flows[flow.destination] = nil
                } else {
                    next = min(next, until)
                }
            case .routing, .forwarding:
                let expiry = flow.lastActivity + settings.flowIdle
                if now >= expiry {
                    finish(flow, error: nil)
                } else {
                    next = min(next, expiry)
                }
            }
        }
        schedule(at: next)
    }

    /// 关闭关联：结束全部流的记录，关闭出站关联与客户端关联（重复调用无副作用）。
    func close() {
        guard !closed else { return }
        closed = true
        timer?.cancel()
        timer = nil
        pending.removeAll()
        for flow in Array(flows.values) {
            finish(flow, error: nil)
        }
        for outbound in outbounds.values {
            outbound.association?.close()
        }
        outbounds.removeAll()
        client.onDatagram = nil
        client.onClose = nil
        client.close()
        let callback = onClosed
        onClosed = nil
        callback?()
    }
}
