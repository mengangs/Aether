import AetherFoundation
import NIOCore

/// 活动 TCP 流的登记与准入控制（docs/06 §13）。绑定到数据面 EventLoop：除 `init` 外的所有方法都必须在该
/// EventLoop 上调用。
///
/// - 并发上限 2048（`NET-040`），超过 1024 时发出一次警告事件（写日志簿）；
/// - 内存压力 critical 期间拒绝新流（`NET-041`，docs/02 §6）；
/// - 流的入站 Channel 关闭时自动注销；
/// - 停止时先半关闭全部流，等待宽限期后强制关闭（docs/06 §2.3）。
public final class FlowManager: @unchecked Sendable {
    public struct Limits: Sendable, Equatable {
        /// 并发 TCP 流上限；达到后新流以 `NET-040` 拒绝。
        public var maxConcurrentFlows = 2048
        /// 超过该数量时发出一次 `warningThresholdExceeded`，回落到一半以下后重新计。
        public var warningThreshold = 1024

        public init() {}
    }

    public enum Event: Sendable, Equatable {
        case warningThresholdExceeded(activeFlows: Int)
        case limitReached(activeFlows: Int)
    }

    private final class Entry {
        var channels: [any Channel]
        let counters: FlowCounters

        init(channel: any Channel, counters: FlowCounters) {
            channels = [channel]
            self.counters = counters
        }
    }

    public let eventLoop: any EventLoop
    public let limits: Limits
    /// 事件回调（在 EventLoop 上调用）。
    public var onEvent: ((Event) -> Void)?

    private var flows: [FlowID: Entry] = [:]
    private var nextID: UInt64 = 1
    private var rejectUntil: NIODeadline?
    private var warned = false

    public init(eventLoop: any EventLoop, limits: Limits = Limits()) {
        self.eventLoop = eventLoop
        self.limits = limits
    }

    /// 当前活动流数。
    public var activeCount: Int {
        eventLoop.preconditionInEventLoop()
        return flows.count
    }

    /// 分配新的流 ID（单调递增，被拒绝的流也占用一个 ID，便于请求记录）。
    public func allocateID() -> FlowID {
        eventLoop.preconditionInEventLoop()
        defer { nextID &+= 1 }
        return FlowID(rawValue: nextID)
    }

    /// 准入检查：内存压力期间或达到并发上限时抛出对应 `NET` 错误。
    public func checkAdmission(now: NIODeadline = .now()) throws {
        eventLoop.preconditionInEventLoop()
        if let rejectUntil {
            if now < rejectUntil {
                throw NetworkError(.netMemoryPressure, "Rejecting new flows under critical memory pressure")
            }
            self.rejectUntil = nil
        }
        if flows.count >= limits.maxConcurrentFlows {
            onEvent?(.limitReached(activeFlows: flows.count))
            throw NetworkError(.netTooManyFlows, "Concurrent flow limit \(limits.maxConcurrentFlows) reached")
        }
    }

    /// 登记一个已准入的流。入站 Channel 关闭时自动注销。
    /// - Throws: 与 `checkAdmission` 相同。
    public func register(_ id: FlowID, inbound channel: any Channel, counters: FlowCounters) throws {
        try checkAdmission()
        flows[id] = Entry(channel: channel, counters: counters)
        if flows.count > limits.warningThreshold, !warned {
            warned = true
            onEvent?(.warningThresholdExceeded(activeFlows: flows.count))
        }
        channel.closeFuture.whenComplete { [self] _ in
            self.remove(id)
        }
    }

    /// 为已登记的流追加 Channel（出站连接建立后），停止与终止时一并关闭。
    public func attach(_ id: FlowID, channel: any Channel) {
        eventLoop.preconditionInEventLoop()
        flows[id]?.channels.append(channel)
    }

    /// 流的计数器；流不存在时为 nil。
    public func counters(for id: FlowID) -> FlowCounters? {
        eventLoop.preconditionInEventLoop()
        return flows[id]?.counters
    }

    /// 当前全部活动流的 ID（升序）。
    public var activeIDs: [FlowID] {
        eventLoop.preconditionInEventLoop()
        return flows.keys.sorted()
    }

    func remove(_ id: FlowID) {
        eventLoop.preconditionInEventLoop()
        flows[id] = nil
        if warned, flows.count < limits.warningThreshold / 2 {
            warned = false
        }
    }

    /// 立即关闭一个流的全部 Channel（IPC `killRequest`）。
    public func close(_ id: FlowID) {
        eventLoop.preconditionInEventLoop()
        guard let entry = flows[id] else { return }
        for channel in entry.channels {
            channel.close(promise: nil)
        }
    }

    /// 在接下来的 `duration` 内拒绝新流（内存压力 critical，docs/02 §6）。
    public func rejectNewFlows(for duration: TimeAmount, now: NIODeadline = .now()) {
        eventLoop.preconditionInEventLoop()
        rejectUntil = now + duration
    }

    /// 关闭全部流：先半关闭（关闭各 Channel 的输出方向），等待 `grace` 后强制关闭仍未结束的 Channel。
    /// - Returns: 全部 Channel 关闭后完成。
    public func closeAll(grace: TimeAmount) -> EventLoopFuture<Void> {
        eventLoop.preconditionInEventLoop()
        let channels = flows.values.flatMap(\.channels)
        guard !channels.isEmpty else { return eventLoop.makeSucceededVoidFuture() }
        for channel in channels {
            channel.close(mode: .output, promise: nil)
        }
        let force = eventLoop.scheduleTask(in: grace) {
            for channel in channels {
                channel.close(promise: nil)
            }
        }
        let all = EventLoopFuture.andAllComplete(channels.map(\.closeFuture), on: eventLoop)
        all.whenComplete { _ in force.cancel() }
        return all
    }
}
