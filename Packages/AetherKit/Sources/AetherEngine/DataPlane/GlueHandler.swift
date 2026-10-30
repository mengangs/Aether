import NIOCore

/// 一个流的字节计数与活动时间（docs/06 §12.1）。绑定到流所在的 EventLoop，只在该 EventLoop 上读写。
public final class FlowCounters {
    /// 客户端 → 服务器。
    public private(set) var bytesUp: UInt64 = 0
    /// 服务器 → 客户端。
    public private(set) var bytesDown: UInt64 = 0
    /// 首个下行字节到达的时间（请求记录的 firstByte）。
    public private(set) var firstDownAt: NIODeadline?
    /// 每次计数时回调（统计聚合用），参数为本次的上行、下行字节数。
    public var onTransfer: ((_ up: Int, _ down: Int) -> Void)?

    public init() {}

    func addUp(_ count: Int) {
        bytesUp &+= UInt64(count)
        onTransfer?(count, 0)
    }

    func addDown(_ count: Int) {
        if firstDownAt == nil {
            firstDownAt = .now()
        }
        bytesDown &+= UInt64(count)
        onTransfer?(0, count)
    }
}

@available(*, unavailable)
extension FlowCounters: Sendable {}

/// 双向「胶水」Handler（参考 SwiftNIO connect-proxy 示例，docs/02 §7、06 §6 第 9 步）。
///
/// 成对使用：一端加在入站 Channel，一端加在出站 Channel。职责：
/// - 把本端读到的字节写到对端，读完一批后 flush；
/// - 背压：对端不可写时本端不再发出 `read()`（不缓冲任何数据），对端恢复可写后补发；
///   因此一个方向在用户态最多缓冲「对端写缓冲高水位 + 一次读取」；
/// - 半关闭：本端读到 EOF 时关闭对端的输出方向；两个方向都结束后关闭双方；
/// - 本端关闭或出错时关闭对端；
/// - 计数：入站一侧读到的字节计为上行，出站一侧计为下行。
public final class GlueHandler: ChannelDuplexHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    public enum Side {
        /// 面向客户端的 Channel（读到的是上行数据）。
        case inbound
        /// 面向服务器的 Channel（读到的是下行数据）。
        case outbound
    }

    private let side: Side
    private let counters: FlowCounters
    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false
    /// 本端已读到 EOF。
    private var inputClosed = false
    /// 本端的输出方向已关闭（对端读到 EOF 后由对端关闭）。
    private var outputClosed = false

    private init(side: Side, counters: FlowCounters) {
        self.side = side
        self.counters = counters
    }

    /// 创建一对互相关联的 Handler：`inbound` 加到客户端 Channel，`outbound` 加到服务器 Channel。
    public static func matchedPair(counters: FlowCounters) -> (inbound: GlueHandler, outbound: GlueHandler) {
        let inbound = GlueHandler(side: .inbound, counters: counters)
        let outbound = GlueHandler(side: .outbound, counters: counters)
        inbound.partner = outbound
        outbound.partner = inbound
        return (inbound, outbound)
    }

    // MARK: 由对端调用

    private func partnerWrite(_ buffer: ByteBuffer) {
        context?.write(wrapOutboundOut(buffer), promise: nil)
    }

    private func partnerFlush() {
        context?.flush()
    }

    private func partnerWriteEOF() {
        guard let context, !outputClosed else { return }
        outputClosed = true
        context.close(mode: .output, promise: nil)
        closeIfFinished()
    }

    private func partnerCloseFull() {
        context?.close(promise: nil)
    }

    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    private var isWritable: Bool {
        context?.channel.isWritable ?? false
    }

    /// 两个方向都已结束：关闭双方。
    private func closeIfFinished() {
        guard let partner else { return }
        if inputClosed && outputClosed && partner.inputClosed && partner.outputClosed {
            context?.close(promise: nil)
            partner.context?.close(promise: nil)
        }
    }

    // MARK: ChannelDuplexHandler

    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        switch side {
        case .inbound: counters.addUp(buffer.readableBytes)
        case .outbound: counters.addDown(buffer.readableBytes)
        }
        partner?.partnerWrite(buffer)
    }

    public func channelReadComplete(context: ChannelHandlerContext) {
        partner?.partnerFlush()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        partner?.partnerCloseFull()
        context.fireChannelInactive()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            inputClosed = true
            partner?.partnerWriteEOF()
            closeIfFinished()
        }
        context.fireUserInboundEventTriggered(event)
    }

    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
        partner?.partnerCloseFull()
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            partner?.partnerBecameWritable()
        }
        context.fireChannelWritabilityChanged()
    }

    public func read(context: ChannelHandlerContext) {
        if let partner, partner.isWritable {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

@available(*, unavailable)
extension GlueHandler: Sendable {}

/// 把一对已建立的 Channel 胶合起来（docs/06 §6 第 9 步）。
public enum FlowRelay {
    /// 在两个 Channel 上安装胶水 Handler 并开始转发。必须在两个 Channel 共同的 EventLoop 上调用。
    ///
    /// - Parameters:
    ///   - initialUpload: 入站一侧已经读出、尚未转发的字节（嗅探窥探到的首包），在转发开始前原样写给服务器。
    ///   - idleTimeout: 双向无数据的时长上限，超过后关闭两端（`NET-005`）。
    /// - Returns: 两个 Channel 都关闭后完成。
    public static func glue(
        inbound: any Channel,
        outbound: any Channel,
        counters: FlowCounters,
        initialUpload: ByteBuffer? = nil,
        idleTimeout: TimeAmount? = EngineTimeouts.default.tcpIdle
    ) throws -> EventLoopFuture<Void> {
        inbound.eventLoop.preconditionInEventLoop()
        precondition(inbound.eventLoop === outbound.eventLoop, "Glued channels must share an EventLoop")
        let (inboundGlue, outboundGlue) = GlueHandler.matchedPair(counters: counters)
        if let initialUpload, initialUpload.readableBytes > 0 {
            counters.addUp(initialUpload.readableBytes)
            outbound.writeAndFlush(initialUpload, promise: nil)
        }
        if let idleTimeout {
            try inbound.pipeline.syncOperations.addHandler(IdleTimeoutHandler(timeout: idleTimeout))
        }
        try inbound.pipeline.syncOperations.addHandler(inboundGlue)
        try outbound.pipeline.syncOperations.addHandler(outboundGlue)
        // 打开 autoRead 后由 NIO 发起读取，胶水 Handler 再按对端可写性放行或暂缓。已激活的 Channel 再经管线发出
        // 一次 read()，使握手阶段留下的字节（回放 Handler）立即交出；尚未注册的 Channel 不能调用 read()：
        // NIO 会认为已有读取在途，激活后不再自动读取。
        for channel in [inbound, outbound] {
            try setAutoRead(channel)
            if channel.isActive {
                channel.read()
            }
        }
        return inbound.closeFuture.and(outbound.closeFuture).map { _ in }
    }

    private static func setAutoRead(_ channel: any Channel) throws {
        if let options = channel.syncOptions {
            try options.setOption(.autoRead, value: true)
        } else {
            channel.setOption(.autoRead, value: true).whenComplete { _ in }
        }
    }
}

/// 双向空闲超时（docs/06 §6.1）：加在入站 Channel 上即可覆盖两个方向——上行数据是本 Channel 的读，
/// 下行数据是本 Channel 的写。时间取自 `EventLoop.now`，测试可用 `EmbeddedEventLoop` 推进。
///
/// 定时器只在到期时检查并按剩余时间重新安排，不随每次读写重置，开销与流量无关。
public final class IdleTimeoutHandler: ChannelDuplexHandler {
    public typealias InboundIn = NIOAny
    public typealias OutboundIn = NIOAny

    private let timeout: TimeAmount
    private var lastActivity: NIODeadline = .uptimeNanoseconds(0)
    private var timer: Scheduled<Void>?
    /// 是否因空闲而关闭（请求记录的 `NET-005`）。
    public private(set) var closedForIdle = false

    public init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        if context.channel.isActive {
            start(context: context)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        timer?.cancel()
        timer = nil
    }

    public func channelActive(context: ChannelHandlerContext) {
        start(context: context)
        context.fireChannelActive()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        timer?.cancel()
        timer = nil
        context.fireChannelInactive()
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        lastActivity = context.eventLoop.now
        context.fireChannelRead(data)
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        lastActivity = context.eventLoop.now
        context.write(data, promise: promise)
    }

    private func start(context: ChannelHandlerContext) {
        guard timer == nil else { return }
        lastActivity = context.eventLoop.now
        schedule(context: context, in: timeout)
    }

    private func schedule(context: ChannelHandlerContext, in delay: TimeAmount) {
        let loopBound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: delay) {
            let (handler, context) = loopBound.value
            handler.check(context: context)
        }
    }

    private func check(context: ChannelHandlerContext) {
        let idle = context.eventLoop.now - lastActivity
        if idle >= timeout {
            closedForIdle = true
            timer = nil
            context.close(promise: nil)
        } else {
            schedule(context: context, in: timeout - idle)
        }
    }
}

@available(*, unavailable)
extension IdleTimeoutHandler: Sendable {}
