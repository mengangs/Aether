import AetherFoundation
import NIOCore

/// 在一条流（TCP / TLS / WebSocket）上收发数据报的帧格式（Trojan、VLESS 的 UDP）。
protocol StreamPacketFraming {
    /// 把一个数据报编码追加到 `buffer`（含首个数据报之前需要的请求头）。
    mutating func encode(_ payload: ByteBuffer, to destination: Destination, into buffer: inout ByteBuffer)
    /// 从 `buffer` 中取出一个完整的数据报；数据不足返回 nil，格式错误抛出。
    mutating func decode(_ buffer: inout ByteBuffer) throws -> (payload: ByteBuffer, source: Destination)?
}

/// 经一条流转发的 UDP 关联（docs/06 §10）。流不可写（对端读得慢）时新数据报直接丢弃并计数，
/// 不在用户态排队；收到的不完整数据报最多缓存一个（≤ 64 KiB + 一次读取）。流关闭即关联结束，格式错误时关闭流。
final class StreamUDPAssociation<Framing: StreamPacketFraming>: OutboundUDPAssociation, @unchecked Sendable {
    var onDatagram: ((ByteBuffer, Destination) -> Void)?
    var closeFuture: EventLoopFuture<Void> { closePromise.futureResult }
    /// 丢弃的数据报数（流不可写、已关闭）。
    private(set) var dropped = 0

    private let channel: any Channel
    private var framing: Framing
    private let closePromise: EventLoopPromise<Void>
    private var closed = false

    init(channel: any Channel, framing: Framing) throws {
        self.channel = channel
        self.framing = framing
        closePromise = channel.eventLoop.makePromise()
        try channel.pipeline.syncOperations.addHandler(StreamUDPReceiver(association: self))
        channel.closeFuture.whenComplete { _ in self.close() }
        ChannelTuning.startReading(channel)
    }

    func send(_ payload: ByteBuffer, to destination: Destination) {
        guard !closed, channel.isWritable, payload.readableBytes <= Int(UInt16.max) else {
            dropped += 1
            return
        }
        var buffer = channel.allocator.buffer(capacity: payload.readableBytes + 64)
        framing.encode(payload, to: destination, into: &buffer)
        channel.writeAndFlush(buffer, promise: nil)
    }

    /// 解出缓冲中的全部完整数据报。
    fileprivate func received(_ buffer: inout ByteBuffer) throws {
        while !closed, let (payload, source) = try framing.decode(&buffer) {
            onDatagram?(payload, source)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        onDatagram = nil
        channel.close(promise: nil)
        closePromise.succeed(())
    }
}

private final class StreamUDPReceiver<Framing: StreamPacketFraming>: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private weak var association: StreamUDPAssociation<Framing>?
    private var pending = ByteBuffer()

    init(association: StreamUDPAssociation<Framing>) {
        self.association = association
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        pending.writeBuffer(&incoming)
        do {
            try association?.received(&pending)
            pending.discardReadBytes()
        } catch {
            context.close(promise: nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
