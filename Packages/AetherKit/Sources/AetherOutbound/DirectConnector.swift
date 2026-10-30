import AetherFoundation
import NIOCore
import NIOPosix

/// DIRECT（docs/06 §8.2）：有域名时经 DIRECT 用途的解析器解析后以 Happy Eyeballs 连接；只有 IP 时直接连接
/// （IPv4-only 网络之外的 NAT64 情形见 `NAT64Support`）。
public struct DirectConnector: OutboundConnector {
    public let name = "DIRECT"
    public let capabilities: OutboundCapabilities = [.tcp, .udp]
    /// DIRECT 用途的解析器（遵守 `[Host]`，docs/07 §2.2）。
    public let resolver: any ServerAddressResolver
    public let nat64: NAT64Support?

    public init(resolver: any ServerAddressResolver, nat64: NAT64Support? = nil) {
        self.resolver = resolver
        self.nat64 = nat64
    }

    public func connect(to destination: Destination, context: DialContext) -> EventLoopFuture<any Channel> {
        TCPDialer.connect(
            host: destination.hostText, port: destination.port, resolver: resolver, nat64: nat64,
            eventLoop: context.eventLoop)
    }

    public func openUDP(context: DialContext) -> EventLoopFuture<any OutboundUDPAssociation> {
        context.eventLoop.makeSucceededFuture(DirectUDPAssociation(eventLoop: context.eventLoop, resolver: resolver))
    }
}

/// DIRECT 的 UDP 关联：每个地址族一个非连接的 UDP socket（完全锥形 NAT 行为），按需创建；域名目标经解析器解析，
/// 结果在关联内缓存（最多 64 个域名，溢出时清空重来）。
public final class DirectUDPAssociation: OutboundUDPAssociation, @unchecked Sendable {
    static let resolvedLimit = 64

    public var onDatagram: ((ByteBuffer, Destination) -> Void)?
    public var closeFuture: EventLoopFuture<Void> { closePromise.futureResult }
    /// 丢弃的数据报数（解析失败、socket 错误）。
    public private(set) var dropped = 0

    private let eventLoop: any EventLoop
    private let resolver: any ServerAddressResolver
    private let closePromise: EventLoopPromise<Void>
    private var sockets: [AddressFamily: EventLoopFuture<any Channel>] = [:]
    private var resolved: [String: IPAddress] = [:]
    private var closed = false

    init(eventLoop: any EventLoop, resolver: any ServerAddressResolver) {
        self.eventLoop = eventLoop
        self.resolver = resolver
        closePromise = eventLoop.makePromise()
    }

    public func send(_ payload: ByteBuffer, to destination: Destination) {
        eventLoop.preconditionInEventLoop()
        guard !closed else { return }
        switch destination {
        case .ip(let address, let port):
            send(payload, to: address.unmappedIPv4, port: port)
        case .domain(let host, let port):
            if let address = resolved[host.value] {
                send(payload, to: address, port: port)
                return
            }
            resolver.resolve(host.value, family: .v4, on: eventLoop)
                .flatMap { v4 -> EventLoopFuture<[IPAddress]> in
                    v4.isEmpty
                        ? self.resolver.resolve(host.value, family: .v6, on: self.eventLoop)
                        : self.eventLoop.makeSucceededFuture(v4)
                }
                .hop(to: eventLoop)
                .whenComplete { result in
                    guard case .success(let addresses) = result, let address = addresses.first else {
                        self.dropped += 1
                        return
                    }
                    if self.resolved.count >= Self.resolvedLimit {
                        self.resolved.removeAll()
                    }
                    self.resolved[host.value] = address
                    self.send(payload, to: address, port: port)
                }
        }
    }

    private func send(_ payload: ByteBuffer, to address: IPAddress, port: UInt16) {
        guard let target = try? SocketAddress(ipAddress: address.description, port: Int(port)) else {
            dropped += 1
            return
        }
        let family: AddressFamily = address.isIPv4 ? .v4 : .v6
        socket(for: family).whenComplete { result in
            switch result {
            case .success(let channel):
                channel.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: payload)).whenFailure { _ in
                    self.dropped += 1
                }
            case .failure:
                self.dropped += 1
            }
        }
    }

    private func socket(for family: AddressFamily) -> EventLoopFuture<any Channel> {
        if let existing = sockets[family] {
            return existing
        }
        let handler = DirectUDPReceiver(association: self)
        let future = DatagramBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(handler) }
            }
            .bind(host: family == .v4 ? "0.0.0.0" : "::", port: 0)
            .map { $0 as any Channel }
        sockets[family] = future
        return future
    }

    func received(_ envelope: AddressedEnvelope<ByteBuffer>) {
        guard !closed, let ip = envelope.remoteAddress.ipAddress, let address = IPAddress(ip),
            let port = envelope.remoteAddress.port
        else { return }
        onDatagram?(envelope.data, .ip(address.unmappedIPv4, port: UInt16(clamping: port)))
    }

    public func close() {
        guard !closed else { return }
        closed = true
        onDatagram = nil
        for future in sockets.values {
            future.whenSuccess { $0.close(promise: nil) }
        }
        sockets.removeAll()
        closePromise.succeed(())
    }
}

private final class DirectUDPReceiver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private weak var association: DirectUDPAssociation?

    init(association: DirectUDPAssociation) {
        self.association = association
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        association?.received(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // 单个数据报的发送错误（ICMP 不可达等）不关闭 socket。
    }
}

/// 握手完成后仍留在管线中的字节：第一次 `read()` 经过时先把它们交给后面的 Handler，然后移除自己。
/// 用于代理协议握手时服务器紧跟响应发来的数据。
final class PendingBytesReplayHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer

    private var pending: ByteBuffer?

    init(pending: ByteBuffer) {
        self.pending = pending
    }

    func read(context: ChannelHandlerContext) {
        if let pending {
            self.pending = nil
            context.fireChannelRead(wrapInboundOut(pending))
            context.fireChannelReadComplete()
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        }
        context.read()
    }
}

@available(*, unavailable)
extension PendingBytesReplayHandler: Sendable {}
