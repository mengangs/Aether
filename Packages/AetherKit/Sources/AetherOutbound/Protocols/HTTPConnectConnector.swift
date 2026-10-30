import AetherFoundation
import Foundation
import NIOCore

/// 代理节点的服务器端点与传输层（docs/04 §5.2–§5.4、06 §8.1）：TCP → TLS（若有）→ WebSocket（若有）。
public struct ProxyServer: Sendable, Hashable {
    public var host: String
    public var port: UInt16
    public var addressPreference: AddressFamilyPreference
    /// 为 nil 时为明文 TCP。
    public var tls: TLSClientOptions?
    /// 为 nil 时不使用 WebSocket。
    public var webSocket: WebSocketClientOptions?

    public init(
        host: String, port: UInt16, addressPreference: AddressFamilyPreference = .dual, tls: TLSClientOptions? = nil,
        webSocket: WebSocketClientOptions? = nil
    ) {
        self.host = host
        self.port = port
        self.addressPreference = addressPreference
        self.tls = tls
        self.webSocket = webSocket
    }

    /// 连接服务器并逐层完成传输层握手。TLS 失败以 `TLSError` 结束（请求记录归入 `NET-033`）；
    /// WebSocket 升级失败见 `WebSocketTransport`。任一层失败时关闭连接。
    public func dial(context: DialContext) -> EventLoopFuture<any Channel> {
        var future = TCPDialer.connect(
            host: host, port: port, preference: addressPreference, resolver: context.serverResolver, nat64: nil,
            eventLoop: context.eventLoop)
        let host = self.host
        let port = self.port
        let deadline = context.deadline
        if let tls {
            future = future.flatMap { channel in
                TLSTransport.handshake(on: channel, serverHost: host, options: tls, deadline: deadline)
                    .closingOnFailure(channel)
            }
        }
        if let webSocket {
            let tls = self.tls
            future = future.flatMap { channel in
                WebSocketTransport.upgrade(
                    on: channel, serverHost: host, port: port, tls: tls, options: webSocket, deadline: deadline
                ).closingOnFailure(channel)
            }
        }
        return future
    }
}

extension EventLoopFuture where Value == any Channel {
    /// 失败时关闭 `channel` 并原样传递错误。
    func closingOnFailure(_ channel: any Channel) -> EventLoopFuture<any Channel> {
        flatMapErrorThrowing { error in
            channel.close(promise: nil)
            throw error
        }
    }
}

/// HTTP / HTTPS 代理（RFC 9110 §9.3.6，docs/06 §8.4）：`CONNECT host:port`，可带 `Proxy-Authorization: Basic`。
/// 非 2xx → `NET-030`（附状态码），407 → `NET-031`。
public struct HTTPConnectConnector: OutboundConnector {
    public let name: String
    public let capabilities: OutboundCapabilities = [.tcp, .remoteResolve]
    public let server: ProxyServer
    public let username: String?
    public let password: String?

    public init(name: String, server: ProxyServer, username: String?, password: String?) {
        self.name = name
        self.server = server
        self.username = username
        self.password = password
    }

    /// `Proxy-Authorization` 的值。
    var authorization: String? {
        guard let username else { return nil }
        let credentials = "\(username):\(password ?? "")"
        return "Basic " + Data(credentials.utf8).base64EncodedString()
    }

    public func connect(to destination: Destination, context: DialContext) -> EventLoopFuture<any Channel> {
        let authorization = self.authorization
        let deadline = context.deadline
        return server.dial(context: context).flatMap { channel in
            let promise = channel.eventLoop.makePromise(of: (any Channel).self)
            let handler = HTTPConnectHandshakeHandler(
                destination: destination, authorization: authorization, promise: promise)
            do {
                try channel.pipeline.syncOperations.addHandler(handler)
            } catch {
                channel.close(promise: nil)
                return channel.eventLoop.makeFailedFuture(NetworkError(.netProtocolError, "\(error)"))
            }
            let timer = channel.eventLoop.scheduleTask(deadline: deadline) {
                promise.fail(NetworkError(.netConnectTimeout, "HTTP CONNECT handshake timed out"))
                channel.close(promise: nil)
            }
            promise.futureResult.whenComplete { _ in timer.cancel() }
            return promise.futureResult
        }
    }
}

/// 发送 `CONNECT`，读取响应头（上限 16 KiB），成功后移除自己；响应头之后紧跟的数据交给 `PendingBytesReplayHandler`。
final class HTTPConnectHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let maxHeaderBytes = 16 * 1024

    private let destination: Destination
    private let authorization: String?
    private let promise: EventLoopPromise<any Channel>
    private var buffer = ByteBuffer()
    private var done = false

    init(destination: Destination, authorization: String?, promise: EventLoopPromise<any Channel>) {
        self.destination = destination
        self.authorization = authorization
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let target = destination.description
        var request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
        if let authorization {
            request += "Proxy-Authorization: \(authorization)\r\n"
        }
        request += "\r\n"
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: request)), promise: nil)
        ChannelTuning.startReading(context.channel)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        let view = buffer.readableBytesView
        guard let end = Self.headerEnd(in: view) else {
            if buffer.readableBytes > Self.maxHeaderBytes {
                fail(context: context, NetworkError(.netProtocolError, "HTTP CONNECT response header too large"))
            }
            return
        }
        guard let headerText = buffer.readString(length: end - view.startIndex) else { return }
        let statusLine = headerText.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            fail(context: context, NetworkError(.netProtocolError, "Malformed CONNECT response"))
            return
        }
        guard (200..<300).contains(status) else {
            let code: AetherErrorCode = status == 407 ? .netProxyAuthFailed : .netProxyHandshakeFailed
            fail(context: context, NetworkError(code, "Proxy answered \(status)"))
            return
        }
        done = true
        let channel = context.channel
        ChannelTuning.stopReading(channel)
        do {
            if buffer.readableBytes > 0 {
                try context.pipeline.syncOperations.addHandler(
                    PendingBytesReplayHandler(pending: buffer), position: .after(self))
            }
        } catch {
            fail(context: context, NetworkError(.netProtocolError, "\(error)"))
            return
        }
        buffer = ByteBuffer()
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        promise.succeed(channel)
    }

    /// `\r\n\r\n` 之后的位置（相对 view 的绝对索引）。
    static func headerEnd(in view: ByteBufferView) -> Int? {
        var index = view.startIndex
        let end = view.endIndex
        while index + 3 < end {
            if view[index] == 13, view[index + 1] == 10, view[index + 2] == 13, view[index + 3] == 10 {
                return index + 4
            }
            index += 1
        }
        return nil
    }

    private func fail(context: ChannelHandlerContext, _ error: NetworkError) {
        done = true
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done {
            done = true
            promise.fail(NetworkError(.netConnectionReset, "Proxy closed the connection during CONNECT"))
        }
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if !done {
            fail(context: context, NetworkError(.netConnectionReset, "\(error)"))
        } else {
            context.fireErrorCaught(error)
        }
    }
}

@available(*, unavailable)
extension HTTPConnectHandshakeHandler: Sendable {}
