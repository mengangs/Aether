import AetherFoundation
import NIOCore
import NIOPosix

/// SOCKS5 / SOCKS5-TLS 代理（RFC 1928、RFC 1929，docs/06 §8.4）。目标有域名时使用域名地址类型（远端解析）。
/// UDP：建立 TCP 控制连接后发 `UDP ASSOCIATE`；`BND.ADDR` 为全零地址时改用服务器地址；控制连接断开即关联失效。
public struct SOCKS5Connector: OutboundConnector {
    public let name: String
    public let server: ProxyServer
    public let username: String?
    public let password: String?
    public let udpEnabled: Bool

    public var capabilities: OutboundCapabilities {
        udpEnabled ? [.tcp, .udp, .remoteResolve] : [.tcp, .remoteResolve]
    }

    public init(name: String, server: ProxyServer, username: String?, password: String?, udpEnabled: Bool) {
        self.name = name
        self.server = server
        self.username = username
        self.password = password
        self.udpEnabled = udpEnabled
    }

    private var credentials: (username: [UInt8], password: [UInt8])? {
        guard let username else { return nil }
        return (Array(username.utf8), Array((password ?? "").utf8))
    }

    public func connect(to destination: Destination, context: DialContext) -> EventLoopFuture<any Channel> {
        handshake(command: 0x01, destination: destination, context: context).map { $0.channel }
    }

    public func openUDP(context: DialContext) -> EventLoopFuture<any OutboundUDPAssociation> {
        guard udpEnabled else {
            return context.eventLoop.makeFailedFuture(NetworkError(.netPolicyNoUDP, "\(name) has UDP relay disabled"))
        }
        let serverHost = server.host
        return handshake(command: 0x03, destination: .ip(.v4(IPv4Address(0)), port: 0), context: context)
            .flatMap { control, bound in
                // BND.ADDR 为全零地址时改用服务器地址（docs/06 §8.4）。
                let relayHost: String
                switch bound {
                case .ip(let address, _) where address == .v4(IPv4Address(0)) || address == IPAddress("::"):
                    relayHost = control.remoteAddress?.ipAddress ?? serverHost
                default:
                    relayHost = bound.hostText
                }
                let relayAddress: SocketAddress
                do {
                    relayAddress = try SocketAddress(ipAddress: relayHost, port: Int(bound.port))
                } catch {
                    control.close(promise: nil)
                    return context.eventLoop.makeFailedFuture(
                        NetworkError(.netProtocolError, "SOCKS5 relay address \(relayHost) is not an IP"))
                }
                return SOCKS5ClientUDPAssociation.open(control: control, relay: relayAddress)
                    .map { $0 as any OutboundUDPAssociation }
            }
    }

    private func handshake(command: UInt8, destination: Destination, context: DialContext) -> EventLoopFuture<
        (channel: any Channel, bound: Destination)
    > {
        let credentials = self.credentials
        let deadline = context.deadline
        return server.dial(context: context).flatMap { channel in
            let promise = channel.eventLoop.makePromise(of: (channel: any Channel, bound: Destination).self)
            let handler = SOCKS5ClientHandshakeHandler(
                command: command, destination: destination, credentials: credentials, promise: promise)
            do {
                try channel.pipeline.syncOperations.addHandler(handler)
            } catch {
                channel.close(promise: nil)
                return channel.eventLoop.makeFailedFuture(NetworkError(.netProtocolError, "\(error)"))
            }
            let timer = channel.eventLoop.scheduleTask(deadline: deadline) {
                promise.fail(NetworkError(.netConnectTimeout, "SOCKS5 handshake timed out"))
                channel.close(promise: nil)
            }
            promise.futureResult.whenComplete { _ in timer.cancel() }
            return promise.futureResult
        }
    }
}

/// SOCKS5 客户端握手。成功后移除自己，回复之后紧跟的数据交给 `PendingBytesReplayHandler`。
final class SOCKS5ClientHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private enum State {
        case method
        case authentication
        case reply
        case done
    }

    private let command: UInt8
    private let destination: Destination
    private let credentials: (username: [UInt8], password: [UInt8])?
    private let promise: EventLoopPromise<(channel: any Channel, bound: Destination)>
    private var state = State.method
    private var buffer = ByteBuffer()

    init(
        command: UInt8, destination: Destination, credentials: (username: [UInt8], password: [UInt8])?,
        promise: EventLoopPromise<(channel: any Channel, bound: Destination)>
    ) {
        self.command = command
        self.destination = destination
        self.credentials = credentials
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // 有凭据时同时提供无认证与用户名 / 密码两种方法，由服务器选择。
        let methods: [UInt8] = credentials == nil ? [0x00] : [0x00, 0x02]
        write(context: context, [5, UInt8(methods.count)] + methods)
        ChannelTuning.startReading(context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard state != .done else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while state != .done, step(context: context) {}
    }

    /// 返回 true 表示进入了下一阶段。
    private func step(context: ChannelHandlerContext) -> Bool {
        switch state {
        case .method:
            guard let reply = buffer.readBytes(length: 2) else { return false }
            guard reply[0] == 5 else {
                fail(context: context, NetworkError(.netProtocolError, "Not a SOCKS5 server"))
                return false
            }
            switch reply[1] {
            case 0x00:
                sendRequest(context: context)
                state = .reply
            case 0x02 where credentials != nil:
                guard let credentials else { return false }
                write(
                    context: context,
                    [1, UInt8(clamping: credentials.username.count)] + credentials.username.prefix(255)
                        + [UInt8(clamping: credentials.password.count)] + credentials.password.prefix(255))
                state = .authentication
            default:
                fail(context: context, NetworkError(.netProxyAuthFailed, "No acceptable SOCKS5 authentication method"))
                return false
            }
            return true
        case .authentication:
            guard let reply = buffer.readBytes(length: 2) else { return false }
            guard reply[1] == 0 else {
                fail(context: context, NetworkError(.netProxyAuthFailed, "SOCKS5 authentication rejected"))
                return false
            }
            sendRequest(context: context)
            state = .reply
            return true
        case .reply:
            guard buffer.readableBytes >= 4 else { return false }
            let base = buffer.readerIndex
            guard let version = buffer.getInteger(at: base, as: UInt8.self),
                let code = buffer.getInteger(at: base + 1, as: UInt8.self)
            else { return false }
            guard version == 5 else {
                fail(context: context, NetworkError(.netProtocolError, "Malformed SOCKS5 reply"))
                return false
            }
            guard code == 0 else {
                fail(context: context, NetworkError(.netProxyHandshakeFailed, "SOCKS5 reply \(code)"))
                return false
            }
            switch SOCKSAddress.parse(buffer, at: 3) {
            case .needMoreData:
                return false
            case .unsupportedType, .invalidDomain:
                fail(context: context, NetworkError(.netProtocolError, "Malformed SOCKS5 bound address"))
                return false
            case .parsed(let bound, let length):
                buffer.moveReaderIndex(forwardBy: 3 + length)
                finish(context: context, bound: bound)
                return false
            }
        case .done:
            return false
        }
    }

    private func sendRequest(context: ChannelHandlerContext) {
        var request = context.channel.allocator.buffer(capacity: 3 + SOCKSAddress.length(of: destination))
        request.writeBytes([5, command, 0])
        SOCKSAddress.write(destination, to: &request)
        context.writeAndFlush(wrapOutboundOut(request), promise: nil)
    }

    private func finish(context: ChannelHandlerContext, bound: Destination) {
        state = .done
        let channel = context.channel
        ChannelTuning.stopReading(channel)
        if buffer.readableBytes > 0 {
            try? context.pipeline.syncOperations.addHandler(
                PendingBytesReplayHandler(pending: buffer), position: .after(self))
        }
        buffer = ByteBuffer()
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        promise.succeed((channel, bound))
    }

    private func write(context: ChannelHandlerContext, _ bytes: [UInt8]) {
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: bytes)), promise: nil)
    }

    private func fail(context: ChannelHandlerContext, _ error: NetworkError) {
        state = .done
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if state != .done {
            state = .done
            promise.fail(NetworkError(.netConnectionReset, "SOCKS5 server closed the connection"))
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if state != .done {
            fail(context: context, NetworkError(.netConnectionReset, "\(error)"))
        } else {
            context.fireErrorCaught(error)
        }
    }
}

@available(*, unavailable)
extension SOCKS5ClientHandshakeHandler: Sendable {}

/// 经 SOCKS5 服务器转发的 UDP 关联：UDP socket 连到服务器的中继地址，载荷加 SOCKS5 UDP 头；控制连接关闭即关联结束。
public final class SOCKS5ClientUDPAssociation: OutboundUDPAssociation, @unchecked Sendable {
    public var onDatagram: ((ByteBuffer, Destination) -> Void)?
    public var closeFuture: EventLoopFuture<Void> { closePromise.futureResult }

    private let control: any Channel
    private let datagram: any Channel
    private let relay: SocketAddress
    private let closePromise: EventLoopPromise<Void>
    private var closed = false

    private init(control: any Channel, datagram: any Channel, relay: SocketAddress) {
        self.control = control
        self.datagram = datagram
        self.relay = relay
        closePromise = control.eventLoop.makePromise()
    }

    static func open(control: any Channel, relay: SocketAddress) -> EventLoopFuture<SOCKS5ClientUDPAssociation> {
        let receiver = SOCKS5ClientUDPReceiver()
        return DatagramBootstrap(group: control.eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(receiver) }
            }
            .bind(host: relay.protocol == .inet6 ? "::" : "0.0.0.0", port: 0)
            .map { datagram in
                let association = SOCKS5ClientUDPAssociation(control: control, datagram: datagram, relay: relay)
                receiver.association = association
                // 控制连接上不再有数据；它读到 EOF 或关闭即关联结束。必须保持读取：kqueue（Apple 平台）只在
                // 有读取兴趣时报告对端 EOF，握手后停止读取会使关联永远察觉不到服务器关闭了控制连接。
                try? control.pipeline.syncOperations.addHandler(ControlWatcher())
                ChannelTuning.startReading(control)
                control.closeFuture.whenComplete { _ in association.close() }
                datagram.closeFuture.whenComplete { _ in association.close() }
                return association
            }
            .flatMapErrorThrowing { error in
                control.close(promise: nil)
                throw NetworkErrorMapping.map(error)
            }
    }

    public func send(_ payload: ByteBuffer, to destination: Destination) {
        guard !closed else { return }
        var buffer = datagram.allocator.buffer(
            capacity: 3 + SOCKSAddress.length(of: destination) + payload.readableBytes)
        buffer.writeBytes([0, 0, 0])
        SOCKSAddress.write(destination, to: &buffer)
        var payload = payload
        buffer.writeBuffer(&payload)
        datagram.writeAndFlush(AddressedEnvelope(remoteAddress: relay, data: buffer), promise: nil)
    }

    func received(_ envelope: AddressedEnvelope<ByteBuffer>) {
        guard !closed, envelope.remoteAddress == relay else { return }
        var data = envelope.data
        guard data.getInteger(at: data.readerIndex + 2, as: UInt8.self) == 0,
            case .parsed(let source, let length) = SOCKSAddress.parse(data, at: 3)
        else { return }
        data.moveReaderIndex(forwardBy: 3 + length)
        onDatagram?(data, source)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        onDatagram = nil
        datagram.close(promise: nil)
        control.close(promise: nil)
        closePromise.succeed(())
    }
}

private final class SOCKS5ClientUDPReceiver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    weak var association: SOCKS5ClientUDPAssociation?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        association?.received(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {}
}

/// 控制连接：丢弃数据，读到 EOF 或出错即关闭。
private final class ControlWatcher: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}

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
