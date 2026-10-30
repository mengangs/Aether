import AetherFoundation
import NIOCore

/// DNS over TCP 的服务端 Handler（docs/07 §2）：TUN 上发往 DNS 地址的 TCP 连接按 2 字节长度前缀分帧，
/// 每个查询交给 `DNSService.answer`，应答按完成顺序写回（RFC 7766 允许乱序）。
///
/// 上限：未处理完的查询最多 16 个，超出后暂停读取；累积的未成帧字节超过 64 KiB + 2 时关闭连接。
public final class DNSStreamServerHandler: ChannelDuplexHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    static let maxPending = 16
    static let maxBuffered = 65_535 + 2

    private let service: DNSService
    private var buffer = ByteBuffer()
    private var pending = 0
    private var readHeld = false
    private var inputClosed = false

    public init(service: DNSService) {
        self.service = service
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard buffer.readableBytes <= Self.maxBuffered else {
            context.close(promise: nil)
            return
        }
        while let frame = DNSStreamFraming.nextFrame(from: &buffer) {
            pending += 1
            let loopBound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
            service.answer(frame, transport: .tcp).whenComplete { result in
                let (handler, context) = loopBound.value
                handler.pending -= 1
                if case .success(.some(let response)) = result {
                    context.writeAndFlush(
                        handler.wrapOutboundOut(DNSStreamFraming.frame(response, allocator: context.channel.allocator)),
                        promise: nil)
                }
                handler.resumeIfPossible(context: context)
            }
        }
        buffer.discardReadBytes()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            inputClosed = true
            resumeIfPossible(context: context)
        }
        context.fireUserInboundEventTriggered(event)
    }

    public func read(context: ChannelHandlerContext) {
        if pending >= Self.maxPending {
            readHeld = true
        } else {
            context.read()
        }
    }

    private func resumeIfPossible(context: ChannelHandlerContext) {
        if inputClosed, pending == 0 {
            context.close(promise: nil)
            return
        }
        if readHeld, pending < Self.maxPending {
            readHeld = false
            context.read()
        }
    }
}

@available(*, unavailable)
extension DNSStreamServerHandler: Sendable {}
