import AetherFoundation
import AetherIPC
import AetherRules
import AetherStore
import Foundation
import NIOCore

/// 流量统计（docs/06 §12.1）。绑定到数据面 EventLoop，所有方法都在该 EventLoop 上调用。
///
/// - 各流的字节数经路由的流量回调汇入：会话总量、按（本地日期、最终节点、接口类型）聚合的待写增量；
/// - 1 Hz 采样器计算上下行速率，保留最近 `sampleLimit`（120）个样本供首页曲线；
/// - 每 `flushInterval`（60 秒）把待写增量交给 `sink`（隧道合并写入 `traffic_daily`，docs/11 §4）；
/// - 待写增量最多 `keyLimit`（1024）个键，超出后新键的流量计入节点名 `(other)`，不丢字节。
public final class TrafficStatistics: @unchecked Sendable {
    public struct Sample: Sendable, Equatable {
        public var at: Date
        /// 上一秒的上行 / 下行字节数（即每秒速率）。
        public var up: UInt64
        public var down: UInt64
    }

    private struct Key: Hashable {
        var day: String
        var policy: String
        var interface: String
    }

    public static let sampleLimit = 120
    public static let keyLimit = 1024
    public static let overflowPolicy = "(other)"

    public let eventLoop: any EventLoop
    private let clock: @Sendable () -> Date
    private let timeZone: TimeZone
    private let network: @Sendable () -> NetworkSnapshot
    private let flushInterval: TimeAmount
    private let sink: (@Sendable ([TrafficDelta]) -> Void)?

    public private(set) var totalUp: UInt64 = 0
    public private(set) var totalDown: UInt64 = 0
    private var samples = CircularBuffer<Sample>(initialCapacity: sampleLimit)
    private var sampledUp: UInt64 = 0
    private var sampledDown: UInt64 = 0
    private var pending: [Key: (up: UInt64, down: UInt64)] = [:]
    /// 会话内按（最终节点、接口类型）的总量，同样最多 `keyLimit` 个键。
    private var session: [SessionKey: (up: UInt64, down: UInt64)] = [:]

    private struct SessionKey: Hashable {
        var policy: String
        var interface: String
    }
    private var sampler: RepeatedTask?
    private var flusher: RepeatedTask?

    public init(
        eventLoop: any EventLoop, clock: @escaping @Sendable () -> Date = { Date() }, timeZone: TimeZone = .current,
        network: @escaping @Sendable () -> NetworkSnapshot = { NetworkSnapshot() },
        flushInterval: TimeAmount = .seconds(60), sink: (@Sendable ([TrafficDelta]) -> Void)? = nil
    ) {
        self.eventLoop = eventLoop
        self.clock = clock
        self.timeZone = timeZone
        self.network = network
        self.flushInterval = flushInterval
        self.sink = sink
    }

    /// 最近的速率样本，旧的在前。
    public var recentSamples: [Sample] { Array(samples) }

    /// 记一笔流量（路由的流量回调）。
    public func record(policy: String, up: Int, down: Int) {
        eventLoop.preconditionInEventLoop()
        let up = UInt64(max(0, up))
        let down = UInt64(max(0, down))
        guard up > 0 || down > 0 else { return }
        totalUp &+= up
        totalDown &+= down
        var key = Key(
            day: TrafficDay.string(for: clock(), timeZone: timeZone), policy: policy,
            interface: Self.interfaceName(network().interfaceType))
        if pending[key] == nil, pending.count >= Self.keyLimit {
            key.policy = Self.overflowPolicy
        }
        let current = pending[key] ?? (0, 0)
        pending[key] = (current.up &+ up, current.down &+ down)
        var sessionKey = SessionKey(policy: policy, interface: key.interface)
        if session[sessionKey] == nil, session.count >= Self.keyLimit {
            sessionKey.policy = Self.overflowPolicy
        }
        let total = session[sessionKey] ?? (0, 0)
        session[sessionKey] = (total.up &+ up, total.down &+ down)
    }

    /// 会话内按（最终节点、接口类型）的总量，按节点、接口排序（`getTraffic`）。
    public var sessionBuckets: [TrafficReport.Bucket] {
        session.map { key, value in
            TrafficReport.Bucket(policy: key.policy, interface: key.interface, up: value.up, down: value.down)
        }.sorted { ($0.policy, $0.interface) < ($1.policy, $1.interface) }
    }

    static func interfaceName(_ type: SubnetCondition.InterfaceType?) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wired: return "wired"
        case nil: return "other"
        }
    }

    /// 启动采样器与定时写入。
    public func start() {
        eventLoop.preconditionInEventLoop()
        guard sampler == nil else { return }
        // 重复任务在本 EventLoop 上执行（本类只在该 EventLoop 上使用）。
        sampler = eventLoop.scheduleRepeatedTask(initialDelay: .seconds(1), delay: .seconds(1)) { _ in
            self.sample()
        }
        flusher = eventLoop.scheduleRepeatedTask(initialDelay: flushInterval, delay: flushInterval) { _ in
            self.flush()
        }
    }

    /// 停止定时器并写出剩余的增量。
    public func stop() {
        eventLoop.preconditionInEventLoop()
        sampler?.cancel()
        flusher?.cancel()
        sampler = nil
        flusher = nil
        flush()
    }

    func sample() {
        let sample = Sample(at: clock(), up: totalUp &- sampledUp, down: totalDown &- sampledDown)
        sampledUp = totalUp
        sampledDown = totalDown
        if samples.count >= Self.sampleLimit {
            samples.removeFirst()
        }
        samples.append(sample)
    }

    /// 取出待写增量（按日期、节点、接口排序）。
    func takePending() -> [TrafficDelta] {
        let deltas = pending.map { key, value in
            TrafficDelta(day: key.day, policy: key.policy, interface: key.interface, up: value.up, down: value.down)
        }.sorted { ($0.day, $0.policy, $0.interface) < ($1.day, $1.policy, $1.interface) }
        pending.removeAll()
        return deltas
    }

    /// 把待写增量交给 `sink`。
    public func flush() {
        eventLoop.preconditionInEventLoop()
        let deltas = takePending()
        if !deltas.isEmpty {
            sink?(deltas)
        }
    }
}
