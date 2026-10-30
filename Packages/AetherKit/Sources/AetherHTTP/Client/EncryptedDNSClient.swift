import AetherFoundation
import AetherOutbound
import Foundation
import NIOCore

/// 加密 DNS 上游的连接参数（docs/07 §4）。
public struct EncryptedDNSEndpoint: Sendable {
    public var host: String
    public var port: UInt16
    /// 证书校验与 SNI（默认完整验证，SNI 为 `host`）。
    public var tls: TLSClientOptions
    /// 解析服务器域名（只走普通 DNS，避免自举循环）。
    public var resolver: any ServerAddressResolver
    /// 单次查询的超时。
    public var timeout: TimeAmount

    public init(
        host: String, port: UInt16, tls: TLSClientOptions = TLSClientOptions(), resolver: any ServerAddressResolver,
        timeout: TimeAmount = .seconds(5)
    ) {
        self.host = host
        self.port = port
        self.tls = tls
        self.resolver = resolver
        self.timeout = timeout
    }

    /// 建立 TCP 连接并完成 TLS 握手（经 DIRECT）。`onNegotiated` 收到 ALPN 结果。
    func connect(on eventLoop: any EventLoop, onNegotiated: (@Sendable (String?) -> Void)? = nil)
        -> EventLoopFuture<any Channel>
    {
        let host = self.host
        let tls = self.tls
        let deadline = NIODeadline.now() + timeout
        return TCPDialer.connect(host: host, port: port, resolver: resolver, nat64: nil, eventLoop: eventLoop)
            .flatMap { channel in
                TLSTransport.handshake(
                    on: channel, serverHost: host, options: tls, deadline: deadline, onNegotiated: onNegotiated
                ).closingOnFailureForDNS(channel)
            }
    }
}

extension EventLoopFuture where Value == any Channel {
    fileprivate func closingOnFailureForDNS(_ channel: any Channel) -> EventLoopFuture<any Channel> {
        flatMapErrorThrowing { error in
            channel.close(promise: nil)
            throw error
        }
    }
}

/// DNS 报文 ID 的读写（前 2 字节）。
enum DNSMessageID {
    static func get(_ message: [UInt8]) -> UInt16? {
        message.count >= 2 ? UInt16(message[0]) << 8 | UInt16(message[1]) : nil
    }

    static func set(_ id: UInt16, in message: [UInt8]) -> [UInt8] {
        var copy = message
        if copy.count >= 2 {
            copy[0] = UInt8(id >> 8)
            copy[1] = UInt8(id & 0xFF)
        }
        return copy
    }
}

/// DNS over TLS（RFC 7858，docs/07 §4）：一条长连接，2 字节长度分帧，允许流水线。
///
/// - 线上的报文 ID 由客户端重新分配，应答按 ID 交回并恢复原 ID，并发查询不会因调用方的 ID 冲突而串线；
/// - 同时等待应答的查询最多 `maxInFlight` 个（64），超出时直接失败；
/// - 连接关闭或出错时，在途查询在新连接上重发一次（服务端在应答之后关闭空闲连接很常见），再次失败才报错；
///   `reset()` 主动关闭（网络变化时）。
/// 绑定到创建它的 EventLoop。
public final class DNSOverTLSClient: @unchecked Sendable {
    public static let maxInFlight = 64

    public let endpoint: EncryptedDNSEndpoint
    public let eventLoop: any EventLoop

    private var connection: EventLoopFuture<any Channel>?
    private var currentChannel: (any Channel)?
    private struct Pending {
        var original: UInt16
        var promise: EventLoopPromise<[UInt8]>
        /// 线上的报文（已换成线上 ID 并加长度前缀）。
        var framed: ByteBuffer
        var retried = false
    }

    private var pending: [UInt16: Pending] = [:]
    private var nextID = UInt16.random(in: .min ... .max)

    public init(endpoint: EncryptedDNSEndpoint, eventLoop: any EventLoop) {
        self.endpoint = endpoint
        self.eventLoop = eventLoop
    }

    /// 查询，返回原始应答（ID 与查询相同）。
    public func query(_ message: [UInt8]) -> EventLoopFuture<[UInt8]> {
        guard eventLoop.inEventLoop else {
            return eventLoop.flatSubmit { self.query(message) }
        }
        guard let original = DNSMessageID.get(message) else {
            return eventLoop.makeFailedFuture(NetworkError(.netProtocolError, "DNS query too short"))
        }
        guard pending.count < Self.maxInFlight else {
            return eventLoop.makeFailedFuture(NetworkError(.netTooManyFlows, "Too many DoT queries in flight"))
        }
        var candidate = nextID
        while pending[candidate] != nil {
            candidate &+= 1
        }
        let id = candidate
        nextID = id &+ 1
        let promise = eventLoop.makePromise(of: [UInt8].self)
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt16(message.count))
        buffer.writeBytes(DNSMessageID.set(id, in: message))
        pending[id] = Pending(original: original, promise: promise, framed: buffer)
        let timer = eventLoop.scheduleTask(in: endpoint.timeout) {
            if let entry = self.pending.removeValue(forKey: id) {
                entry.promise.fail(NetworkError(.netConnectTimeout, "DoT query timed out"))
            }
        }
        promise.futureResult.whenComplete { _ in timer.cancel() }
        transmit(id)
        return promise.futureResult
    }

    private func transmit(_ id: UInt16) {
        channel().whenComplete { result in
            switch result {
            case .success(let channel):
                if let framed = self.pending[id]?.framed {
                    channel.writeAndFlush(framed, promise: nil)
                }
            case .failure(let error):
                if let entry = self.pending.removeValue(forKey: id) {
                    entry.promise.fail(error)
                }
            }
        }
    }

    /// 关闭连接（在途查询失败）。
    public func reset() {
        eventLoop.execute {
            self.connection?.whenSuccess { $0.close(promise: nil) }
            self.connection = nil
        }
    }

    /// 当前连接；已失效（对端已关闭但关闭通知还没到）时同步丢弃再重连，保证并发调用只建一条新连接。
    private func channel() -> EventLoopFuture<any Channel> {
        if let current = currentChannel, !current.isActive {
            connection = nil
            currentChannel = nil
        }
        if let connection {
            return connection
        }
        return reconnect()
    }

    private func reconnect() -> EventLoopFuture<any Channel> {
        let future = endpoint.connect(on: eventLoop).flatMapThrowing { channel -> any Channel in
            try channel.pipeline.syncOperations.addHandler(DoTResponseHandler(client: self))
            try channel.syncOptions?.setOption(.autoRead, value: true)
            channel.read()
            self.currentChannel = channel
            channel.closeFuture.whenComplete { _ in self.connectionClosed(channel) }
            return channel
        }
        future.whenFailure { _ in
            self.connection = nil
        }
        connection = future
        return future
    }

    fileprivate func received(_ message: [UInt8]) {
        guard let id = DNSMessageID.get(message), let entry = pending.removeValue(forKey: id) else { return }
        entry.promise.succeed(DNSMessageID.set(entry.original, in: message))
    }

    private func connectionClosed(_ channel: any Channel) {
        eventLoop.execute {
            // 只有当前连接关闭才清掉缓存（旧连接的关闭通知可能晚于新连接建立）。
            guard self.currentChannel === channel else { return }
            self.connection = nil
            self.currentChannel = nil
            for (id, entry) in self.pending {
                if entry.retried {
                    self.pending[id] = nil
                    entry.promise.fail(NetworkError(.netConnectionReset, "DoT connection closed"))
                } else {
                    self.pending[id]?.retried = true
                    self.transmit(id)
                }
            }
        }
    }
}

/// 解出 2 字节长度分帧的应答交给客户端；帧长为 0 或连接出错时关闭。缓冲最多一个应答（≤ 64 KiB + 一次读取）。
private final class DoTResponseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private weak var client: DNSOverTLSClient?
    private var buffer = ByteBuffer()

    init(client: DNSOverTLSClient) {
        self.client = client
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self),
            buffer.readableBytes >= 2 + Int(length)
        {
            guard length > 0 else {
                context.close(promise: nil)
                return
            }
            buffer.moveReaderIndex(forwardBy: 2)
            if let message = buffer.readBytes(length: Int(length)) {
                client?.received(message)
            }
        }
        buffer.discardReadBytes()
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
