import AetherFoundation
import AetherOutbound
import Foundation
import NIOCore
import NIOHTTP1
import NIOHTTP2

/// DNS over HTTPS（RFC 8484，docs/07 §4）：`POST application/dns-message`，线上的报文 ID 为 0（应答恢复原 ID）。
///
/// - TLS 的 ALPN 依次提供 `h2` 与 `http/1.1`：协商出 h2 时一条连接上每个查询一个流；否则为 HTTP/1.1 长连接，
///   一次一个请求，其余排队；
/// - 在途（h2）或排队（HTTP/1.1）的查询最多 64 个，超出直接失败；应答正文上限 64 KiB；
/// - 非 200 应答、连接关闭或超时都使对应查询失败；连接关闭后下一次查询重新建立；`reset()` 主动关闭（网络变化时）。
/// 绑定到创建它的 EventLoop。
public final class DNSOverHTTPSClient: @unchecked Sendable {
    public static let maxOutstanding = 64
    static let maxResponseBytes = 64 * 1024

    public let endpoint: EncryptedDNSEndpoint
    public let eventLoop: any EventLoop
    /// 请求路径（含查询串）。
    public let path: String
    private let authority: String

    private enum Connection {
        case http2(any Channel, NIOHTTP2Handler.StreamMultiplexer)
        case http1(any Channel, HTTP1Exchange)

        var channel: any Channel {
            switch self {
            case .http2(let channel, _), .http1(let channel, _): return channel
            }
        }
    }

    private var connection: EventLoopFuture<Connection>?
    private var outstanding = 0

    /// `url` 必须为 `https://主机[:端口]/路径`；否则返回 nil。
    public init?(
        url: String, resolver: any ServerAddressResolver, tls: TLSClientOptions = TLSClientOptions(),
        timeout: TimeAmount = .seconds(5), eventLoop: any EventLoop
    ) {
        guard let target = HTTPProbe.Target(url), target.secure else { return nil }
        var options = tls
        options.alpn = ["h2", "http/1.1"]
        endpoint = EncryptedDNSEndpoint(
            host: target.host, port: target.port, tls: options, resolver: resolver, timeout: timeout)
        path = target.path
        authority = target.hostHeader
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
        guard outstanding < Self.maxOutstanding else {
            return eventLoop.makeFailedFuture(NetworkError(.netTooManyFlows, "Too many DoH queries outstanding"))
        }
        outstanding += 1
        let promise = eventLoop.makePromise(of: [UInt8].self)
        let timer = eventLoop.scheduleTask(in: endpoint.timeout) {
            promise.fail(NetworkError(.netConnectTimeout, "DoH query timed out"))
        }
        promise.futureResult.whenComplete { _ in
            timer.cancel()
            self.outstanding -= 1
        }
        let body = DNSMessageID.set(0, in: message)
        connect().whenComplete { result in
            switch result {
            case .failure(let error):
                promise.fail(error)
            case .success(.http2(_, let multiplexer)):
                self.send(body, over: multiplexer, promise: promise)
            case .success(.http1(let channel, let exchange)):
                exchange.enqueue(self.request(body), body: body, channel: channel, promise: promise)
            }
        }
        return promise.futureResult.map { DNSMessageID.set(original, in: $0) }
    }

    /// 关闭连接。
    public func reset() {
        eventLoop.execute {
            self.connection?.whenSuccess { $0.channel.close(promise: nil) }
            self.connection = nil
        }
    }

    private func request(_ body: [UInt8]) -> HTTPRequestHead {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: authority)
        headers.add(name: "Content-Type", value: "application/dns-message")
        headers.add(name: "Accept", value: "application/dns-message")
        headers.add(name: "Content-Length", value: String(body.count))
        return HTTPRequestHead(version: .http1_1, method: .POST, uri: path, headers: headers)
    }

    private func send(
        _ body: [UInt8], over multiplexer: NIOHTTP2Handler.StreamMultiplexer, promise: EventLoopPromise<[UInt8]>
    ) {
        let head = request(body)
        multiplexer.createStreamChannel { stream in
            stream.eventLoop.makeCompletedFuture {
                try stream.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ClientCodec(httpProtocol: .https))
                try stream.pipeline.syncOperations.addHandler(DoHResponseCollector(promise: promise))
            }
        }.whenComplete { result in
            switch result {
            case .failure(let error):
                promise.fail(NetworkError(.netConnectionReset, "DoH stream failed: \(error)"))
            case .success(let stream):
                stream.write(HTTPClientRequestPart.head(head), promise: nil)
                stream.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: body))), promise: nil)
                stream.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
                promise.futureResult.whenComplete { _ in stream.close(promise: nil) }
            }
        }
    }

    private func connect() -> EventLoopFuture<Connection> {
        if let connection {
            return connection
        }
        let negotiated = NIOLoopBoundBox<String?>(nil, eventLoop: eventLoop)
        let eventLoop = self.eventLoop
        // 回调在连接的 EventLoop 上、握手 future 完成之前同步调用。
        let future = endpoint.connect(on: eventLoop) { protocolName in
            negotiated.value = protocolName
        }.flatMapThrowing { channel -> Connection in
            let connection: Connection
            if negotiated.value == "h2" {
                let multiplexer = try channel.pipeline.syncOperations.configureHTTP2Pipeline(
                    mode: .client, connectionConfiguration: .init(), streamConfiguration: .init()
                ) { stream in stream.close() }
                connection = .http2(channel, multiplexer)
            } else {
                try channel.pipeline.syncOperations.addHTTPClientHandlers()
                let exchange = HTTP1Exchange()
                try channel.pipeline.syncOperations.addHandler(DoHResponseRouter(exchange: exchange))
                connection = .http1(channel, exchange)
            }
            try channel.syncOptions?.setOption(.autoRead, value: true)
            channel.read()
            channel.closeFuture.whenComplete { _ in
                eventLoop.execute { self.connection = nil }
            }
            return connection
        }
        future.whenFailure { _ in self.connection = nil }
        connection = future
        return future
    }
}

/// 收集一个 HTTP 应答：200 时交出正文，其它状态码、正文超限或流提前结束时失败。
private final class DoHResponseCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<[UInt8]>
    private var status: HTTPResponseStatus?
    private var body: [UInt8] = []

    init(promise: EventLoopPromise<[UInt8]>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = head.status
        case .body(let buffer):
            body += buffer.readableBytesView
            if body.count > DNSOverHTTPSClient.maxResponseBytes {
                promise.fail(NetworkError(.netProtocolError, "DoH response too large"))
                context.close(promise: nil)
            }
        case .end:
            if status == .ok {
                promise.succeed(body)
            } else {
                promise.fail(NetworkError(.netProxyHandshakeFailed, "DoH server answered \(status?.code ?? 0)"))
            }
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(NetworkError(.netConnectionReset, "DoH stream closed"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise.fail(NetworkError(.netProtocolError, "\(error)"))
        context.close(promise: nil)
    }
}

/// HTTP/1.1 的请求队列：一次一个请求，应答到达后发送下一个。只在连接的 EventLoop 上使用。
final class HTTP1Exchange: @unchecked Sendable {
    private var queue: [(head: HTTPRequestHead, body: [UInt8], promise: EventLoopPromise<[UInt8]>)] = []
    private var current: EventLoopPromise<[UInt8]>?
    private var status: HTTPResponseStatus?
    private var body: [UInt8] = []
    private weak var channel: (any Channel)?

    func enqueue(
        _ head: HTTPRequestHead, body: [UInt8], channel: any Channel, promise: EventLoopPromise<[UInt8]>
    ) {
        self.channel = channel
        queue.append((head, body, promise))
        sendNext()
    }

    private func sendNext() {
        guard current == nil, !queue.isEmpty, let channel else { return }
        let next = queue.removeFirst()
        current = next.promise
        status = nil
        body = []
        channel.write(HTTPClientRequestPart.head(next.head), promise: nil)
        channel.write(HTTPClientRequestPart.body(.byteBuffer(ByteBuffer(bytes: next.body))), promise: nil)
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
    }

    fileprivate func received(_ part: HTTPClientResponsePart) {
        switch part {
        case .head(let head):
            status = head.status
        case .body(let buffer):
            body += buffer.readableBytesView
        case .end:
            let promise = current
            current = nil
            if status == .ok, body.count <= DNSOverHTTPSClient.maxResponseBytes {
                promise?.succeed(body)
            } else {
                promise?.fail(NetworkError(.netProxyHandshakeFailed, "DoH server answered \(status?.code ?? 0)"))
            }
            sendNext()
        }
    }

    fileprivate func failAll(_ error: any Error) {
        current?.fail(error)
        current = nil
        for entry in queue {
            entry.promise.fail(error)
        }
        queue.removeAll()
    }
}

private final class DoHResponseRouter: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let exchange: HTTP1Exchange

    init(exchange: HTTP1Exchange) {
        self.exchange = exchange
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        exchange.received(unwrapInboundIn(data))
    }

    func channelInactive(context: ChannelHandlerContext) {
        exchange.failAll(NetworkError(.netConnectionReset, "DoH connection closed"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        exchange.failAll(NetworkError(.netProtocolError, "\(error)"))
        context.close(promise: nil)
    }
}
