import AetherFoundation
import AetherOutbound
import AetherRules
import NIOCore
import NIOPosix

/// SOCKS5 用户名 / 密码（RFC 1929）。内部入站的凭据在每次启动隧道时随机生成（docs/06 §4.2）。
public struct SOCKS5Credentials: Sendable, Equatable {
    public var username: [UInt8]
    public var password: [UInt8]

    public init(username: String, password: String) {
        self.username = Array(username.utf8)
        self.password = Array(password.utf8)
    }

    /// 随机生成 16 字节、十六进制表示的用户名与密码。
    public static func random<G: RandomNumberGenerator>(using generator: inout G) -> SOCKS5Credentials {
        func token() -> String {
            Bytes.hex((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        }
        return SOCKS5Credentials(username: token(), password: token())
    }

    public static func random() -> SOCKS5Credentials {
        var generator = SystemRandomNumberGenerator()
        return random(using: &generator)
    }
}

/// SOCKS5 服务端握手（RFC 1928、RFC 1929；docs/06 §5.1）。
///
/// - `credentials` 不为 nil 时只接受用户名 / 密码认证，否则只接受无认证；
/// - `CONNECT`：认证成功后**立即**回复成功（`BND` 为 `0.0.0.0:0`），以便路由在连接出站之前嗅探客户端首包；
///   然后关闭 `autoRead`、移除本 Handler，把 Channel 与握手后已读到的字节交给 `InboundAcceptor`；
/// - `UDP ASSOCIATE`：在 `127.0.0.1` 上绑定一个 UDP 端口并回复它；控制连接关闭即关联结束；
/// - `BIND` 与未知命令回复 0x07，未知地址类型回复 0x08；
/// - 握手必须在 `handshakeTimeout` 内完成，未完成的握手缓冲不超过 1 KiB（超出即关闭）。
public final class SOCKS5ServerHandler: ChannelInboundHandler, RemovableChannelHandler {
    public typealias InboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    static let maxHandshakeBytes = 1024

    enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    private enum State {
        case greeting
        case authentication
        case request
        case done
    }

    private let credentials: SOCKS5Credentials?
    private let acceptor: any InboundAcceptor
    private let inbound: RouteContext.InboundKind
    private let handshakeTimeout: TimeAmount
    private var state = State.greeting
    private var buffer = ByteBuffer()
    private var timer: Scheduled<Void>?

    public init(
        credentials: SOCKS5Credentials?, acceptor: any InboundAcceptor, inbound: RouteContext.InboundKind = .tun,
        handshakeTimeout: TimeAmount = .seconds(10)
    ) {
        self.credentials = credentials
        self.acceptor = acceptor
        self.inbound = inbound
        self.handshakeTimeout = handshakeTimeout
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        let loopBound = NIOLoopBound(context, eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: handshakeTimeout) {
            loopBound.value.close(promise: nil)
        }
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        timer?.cancel()
        timer = nil
    }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard buffer.readableBytes <= Self.maxHandshakeBytes || state == .done else {
            context.close(promise: nil)
            return
        }
        while state != .done {
            guard let progressed = step(context: context), progressed else { break }
        }
    }

    /// 处理一个握手阶段。返回 true 表示消费了数据并进入下一阶段，false 表示数据不足，nil 表示已关闭或已交出。
    private func step(context: ChannelHandlerContext) -> Bool? {
        switch state {
        case .greeting:
            guard let version = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self),
                let count = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self)
            else { return false }
            guard version == 5 else {
                context.close(promise: nil)
                return nil
            }
            guard let methods = buffer.getBytes(at: buffer.readerIndex + 2, length: Int(count)) else { return false }
            buffer.moveReaderIndex(forwardBy: 2 + Int(count))
            let wanted: UInt8 = credentials == nil ? 0x00 : 0x02
            guard methods.contains(wanted) else {
                write(context: context, [5, 0xFF], thenClose: true)
                return nil
            }
            write(context: context, [5, wanted])
            state = credentials == nil ? .request : .authentication
            return true
        case .authentication:
            let base = buffer.readerIndex
            guard let version = buffer.getInteger(at: base, as: UInt8.self),
                let userLength = buffer.getInteger(at: base + 1, as: UInt8.self),
                let username = buffer.getBytes(at: base + 2, length: Int(userLength)),
                let passwordLength = buffer.getInteger(at: base + 2 + Int(userLength), as: UInt8.self),
                let password = buffer.getBytes(at: base + 3 + Int(userLength), length: Int(passwordLength))
            else { return false }
            buffer.moveReaderIndex(forwardBy: 3 + Int(userLength) + Int(passwordLength))
            guard version == 1, let credentials, constantTimeEquals(username, credentials.username),
                constantTimeEquals(password, credentials.password)
            else {
                write(context: context, [1, 1], thenClose: true)
                return nil
            }
            write(context: context, [1, 0])
            state = .request
            return true
        case .request:
            let base = buffer.readerIndex
            guard let version = buffer.getInteger(at: base, as: UInt8.self),
                let command = buffer.getInteger(at: base + 1, as: UInt8.self),
                buffer.getInteger(at: base + 2, as: UInt8.self) != nil
            else { return false }
            guard version == 5 else {
                context.close(promise: nil)
                return nil
            }
            let address = SOCKSAddress.parse(buffer, at: 3)
            let destination: Destination
            switch address {
            case .needMoreData:
                return false
            case .unsupportedType:
                reply(context: context, .addressTypeNotSupported, thenClose: true)
                return nil
            case .invalidDomain:
                reply(context: context, .generalFailure, thenClose: true)
                return nil
            case .parsed(let parsed, let length):
                destination = parsed
                buffer.moveReaderIndex(forwardBy: 3 + length)
            }
            switch command {
            case 0x01:
                connect(context: context, destination: destination)
            case 0x03:
                associate(context: context)
            default:
                reply(context: context, .commandNotSupported, thenClose: true)
            }
            return nil
        case .done:
            return nil
        }
    }

    private func connect(context: ChannelHandlerContext, destination: Destination) {
        state = .done
        timer?.cancel()
        reply(context: context, .succeeded)
        let leftover = buffer.readableBytes > 0 ? buffer : nil
        buffer = ByteBuffer()
        let channel = context.channel
        let port = channel.localAddress?.port.map { UInt16(clamping: $0) }
        let request = InboundTCPRequest(
            inbound: inbound, destination: destination, inboundPort: port, initialData: leftover, replied: true)
        let acceptor = self.acceptor
        // 先停止读取再移除自己：移除后到达的数据会落到管线末端被丢弃。
        if let options = channel.syncOptions {
            try? options.setOption(.autoRead, value: false)
        }
        context.pipeline.syncOperations.removeHandler(context: context).assumeIsolated().whenComplete { _ in
            acceptor.acceptTCP(request, channel: channel)
        }
    }

    private func associate(context: ChannelHandlerContext) {
        state = .done
        timer?.cancel()
        let control = context.channel
        let acceptor = self.acceptor
        let loopBound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        SOCKS5UDPAssociation.bind(control: control).whenComplete { result in
            let (handler, context) = loopBound.value
            switch result {
            case .failure:
                handler.reply(context: context, .generalFailure, thenClose: true)
            case .success(let association):
                var response = context.channel.allocator.buffer(capacity: 10)
                response.writeBytes([5, Reply.succeeded.rawValue, 0])
                SOCKSAddress.write(
                    .ip(.v4(IPv4Address(127, 0, 0, 1)), port: association.port), to: &response)
                context.writeAndFlush(handler.wrapOutboundOut(response), promise: nil)
                // 控制连接上之后的数据一律丢弃；它读到 EOF 或关闭即关联结束（入站允许半关闭，EOF 不会自动关闭连接）。
                do {
                    try context.pipeline.syncOperations.addHandler(UDPControlHandler(), position: .after(handler))
                } catch {
                    association.close()
                    return
                }
                _ = context.pipeline.syncOperations.removeHandler(context: context)
                acceptor.acceptUDP(association)
            }
        }
    }

    private func reply(context: ChannelHandlerContext, _ code: Reply, thenClose: Bool = false) {
        write(context: context, [5, code.rawValue, 0, 1, 0, 0, 0, 0, 0, 0], thenClose: thenClose)
    }

    private func write(context: ChannelHandlerContext, _ bytes: [UInt8], thenClose: Bool = false) {
        let buffer = context.channel.allocator.buffer(bytes: bytes)
        if thenClose {
            state = .done
            let loopBound = NIOLoopBound(context, eventLoop: context.eventLoop)
            context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
                loopBound.value.close(promise: nil)
            }
        } else {
            context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
        }
    }

    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}

@available(*, unavailable)
extension SOCKS5ServerHandler: Sendable {}

/// 一个 SOCKS5 UDP 关联（docs/06 §5.1、§10）：`127.0.0.1` 上的 UDP socket，与 TCP 控制连接同生共死。
///
/// - 只接受来自回环地址的数据报，第一个发送者即客户端，之后只与它通信；
/// - 头部 `FRAG ≠ 0` 的数据报丢弃（docs/06 §10）；
/// - 绑定到数据面 EventLoop：`onDatagram`、`send`、`close` 都在该 EventLoop 上使用。
public final class SOCKS5UDPAssociation: @unchecked Sendable {
    public let control: any Channel
    public let datagram: any Channel
    /// 收到客户端发往 `Destination` 的载荷（由路由设置）。
    public var onDatagram: ((Destination, ByteBuffer) -> Void)?
    /// 关联结束时回调一次。
    public var onClose: (() -> Void)?
    private var client: SocketAddress?
    /// 丢弃的数据报数（`FRAG ≠ 0`、非回环来源、格式错误）。
    public private(set) var droppedDatagrams = 0
    private var closed = false

    public var port: UInt16 {
        UInt16(clamping: datagram.localAddress?.port ?? 0)
    }

    public var eventLoop: any EventLoop { datagram.eventLoop }

    private init(control: any Channel, datagram: any Channel) {
        self.control = control
        self.datagram = datagram
    }

    static func bind(control: any Channel) -> EventLoopFuture<SOCKS5UDPAssociation> {
        let handler = SOCKS5UDPHandler()
        return DatagramBootstrap(group: control.eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(handler)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .map { datagram in
                let association = SOCKS5UDPAssociation(control: control, datagram: datagram)
                handler.association = association
                control.closeFuture.whenComplete { _ in association.close() }
                datagram.closeFuture.whenComplete { _ in association.close() }
                return association
            }
    }

    func received(_ envelope: AddressedEnvelope<ByteBuffer>) {
        guard !closed else { return }
        let sender = envelope.remoteAddress
        if let client {
            guard sender == client else {
                droppedDatagrams += 1
                return
            }
        } else {
            guard let ip = sender.ipAddress, ip == "127.0.0.1" || ip == "::1" else {
                droppedDatagrams += 1
                return
            }
            client = sender
        }
        var data = envelope.data
        guard let fragment = data.getInteger(at: data.readerIndex + 2, as: UInt8.self), fragment == 0 else {
            droppedDatagrams += 1
            return
        }
        guard case .parsed(let destination, let length) = SOCKSAddress.parse(data, at: 3) else {
            droppedDatagrams += 1
            return
        }
        data.moveReaderIndex(forwardBy: 3 + length)
        onDatagram?(destination, data)
    }

    /// 把来自 `source` 的载荷发回客户端（加上 SOCKS5 UDP 头）。客户端尚未发送过数据时丢弃。
    public func send(_ payload: ByteBuffer, from source: Destination) {
        guard !closed, let client else { return }
        var buffer = datagram.allocator.buffer(capacity: payload.readableBytes + 3 + SOCKSAddress.length(of: source))
        buffer.writeBytes([0, 0, 0])
        SOCKSAddress.write(source, to: &buffer)
        var payload = payload
        buffer.writeBuffer(&payload)
        datagram.writeAndFlush(AddressedEnvelope(remoteAddress: client, data: buffer), promise: nil)
    }

    /// 结束关联：关闭 UDP socket 与控制连接（重复调用无副作用）。
    public func close() {
        guard !closed else { return }
        closed = true
        datagram.close(promise: nil)
        control.close(promise: nil)
        let callback = onClose
        onClose = nil
        onDatagram = nil
        callback?()
    }
}

/// UDP 关联的 TCP 控制连接：丢弃数据，读到 EOF 时关闭。
private final class UDPControlHandler: ChannelInboundHandler {
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

@available(*, unavailable)
extension UDPControlHandler: Sendable {}

private final class SOCKS5UDPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    /// 绑定完成后设置（同一 EventLoop 上，绑定完成前不会有数据到达）。
    var association: SOCKS5UDPAssociation?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        association?.received(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        // UDP 的单次发送错误（如目标不可达的 ICMP）不结束关联。
    }
}

/// 内部 SOCKS5 入站的监听（docs/06 §5.1）。
public final class SOCKS5Inbound: Sendable {
    public let channel: any Channel
    public let credentials: SOCKS5Credentials?

    private init(channel: any Channel, credentials: SOCKS5Credentials?) {
        self.channel = channel
        self.credentials = credentials
    }

    /// 实际监听的端口。
    public var port: Int {
        channel.localAddress?.port ?? 0
    }

    /// 在 `host:port`（默认 `127.0.0.1:0`，系统分配端口）上监听。
    public static func start(
        on eventLoop: any EventLoop, host: String = "127.0.0.1", port: Int = 0, credentials: SOCKS5Credentials?,
        acceptor: any InboundAcceptor, inbound: RouteContext.InboundKind = .tun
    ) -> EventLoopFuture<SOCKS5Inbound> {
        ChannelTuning.configure(ServerBootstrap(group: eventLoop))
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(
                        SOCKS5ServerHandler(credentials: credentials, acceptor: acceptor, inbound: inbound))
                }
            }
            .bind(host: host, port: port)
            .map { SOCKS5Inbound(channel: $0, credentials: credentials) }
    }

    /// 停止接受新连接（已建立的流不受影响）。
    public func close() -> EventLoopFuture<Void> {
        channel.close()
    }
}
