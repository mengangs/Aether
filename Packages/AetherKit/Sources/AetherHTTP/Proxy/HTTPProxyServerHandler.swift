import AetherFoundation
import AetherOutbound
import NIOCore
import NIOHTTP1

/// HTTP 代理入站的客户端一侧（docs/06 §5.2）。管线：`HTTPRequestDecoder`（`leftOverBytesStrategy: .forwardBytes`）
/// → `HTTPResponseEncoder` → 本 Handler。
///
/// - `CONNECT host:port`：移除 HTTP 编解码器与本 Handler，把 Channel 交给 `HTTPProxyDelegate.connect`；
/// - 绝对形式请求（`GET http://host/path`）：每个请求单独路由；转发时改为源站形式、去掉逐跳头；同一客户端连接上
///   路由结果的 `reuseKey` 相同则复用上游连接，否则新建；
/// - 其它形式（如 `GET /`）回复 `400` 并关闭；
/// - 一次只处理一个请求：请求体按上游可写性读取，请求结束后暂停读取，直到响应结束（不支持流水线并发，
///   客户端的流水线请求按顺序处理）；
/// - 背压：上游不可写时暂停读客户端，客户端不可写时暂停读上游。
///
/// 这是 M2 的最小转发实现；重写、脚本与抓包在 M5 的 HTTP 管线中加入。
public final class HTTPProxyServerHandler: ChannelDuplexHandler, RemovableChannelHandler {
    public typealias InboundIn = HTTPServerRequestPart
    public typealias OutboundIn = HTTPServerResponsePart
    public typealias OutboundOut = HTTPServerResponsePart

    private enum Phase {
        case idle
        case awaitingConnectEnd(Destination)
        case routing
        case dialing
        case forwarding
        case rejecting
        case closed
    }

    final class Upstream {
        let key: String
        let channel: any Channel
        let relay: HTTPUpstreamRelayHandler
        /// 上游的上一个响应允许复用连接。
        var keepAlive = true

        init(key: String, channel: any Channel, relay: HTTPUpstreamRelayHandler) {
            self.key = key
            self.channel = channel
            self.relay = relay
        }
    }

    private let delegate: any HTTPProxyDelegate
    private var context: ChannelHandlerContext?
    private var phase = Phase.idle
    private var requestHead: HTTPRequestHead?
    private var clientKeepAlive = true
    private var clientVersion = HTTPVersion.http1_1
    private var requestEnded = false
    private var responseStarted = false
    private var responseEnded = false
    private var observer: (any HTTPExchangeObserver)?
    /// 路由与拨号期间到达的请求体（读取在此期间暂停，最多一次读取的量）。
    private var queued: [HTTPServerRequestPart] = []
    private var pendingRead = false
    private var upstream: Upstream?
    private var dropTimer: Scheduled<Void>?

    public init(delegate: any HTTPProxyDelegate) {
        self.delegate = delegate
    }

    public func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    public func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    // MARK: 客户端请求

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            guard case .idle = phase else {
                context.close(promise: nil)
                return
            }
            startRequest(head, context: context)
        case .body(let buffer):
            switch phase {
            case .routing, .dialing:
                queued.append(part)
            case .forwarding:
                observer?.transferred(up: buffer.readableBytes, down: 0)
                upstream?.channel.writeAndFlush(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
            default:
                break
            }
        case .end(let trailers):
            if case .awaitingConnectEnd(let destination) = phase {
                beginConnect(destination, context: context)
                return
            }
            requestEnded = true
            switch phase {
            case .routing, .dialing:
                queued.append(part)
            case .forwarding:
                upstream?.channel.writeAndFlush(HTTPClientRequestPart.end(trailers), promise: nil)
            case .rejecting where responseEnded:
                completeExchange(error: nil)
            default:
                break
            }
        }
    }

    private func startRequest(_ head: HTTPRequestHead, context: ChannelHandlerContext) {
        if head.method == .CONNECT {
            guard let destination = ConnectTarget.parse(head.uri) else {
                respondAndClose(status: .badRequest, context: context)
                return
            }
            phase = .awaitingConnectEnd(destination)
            return
        }
        guard let target = AbsoluteTarget(uri: head.uri),
            let destination = Destination(host: target.host, port: target.port)
        else {
            respondAndClose(status: .badRequest, context: context)
            return
        }
        clientKeepAlive = head.isKeepAlive
        clientVersion = head.version
        requestEnded = false
        responseStarted = false
        responseEnded = false
        queued = []
        var upstreamHead = head
        upstreamHead.uri = target.originForm
        HTTPHopByHop.strip(&upstreamHead.headers)
        if !upstreamHead.headers.contains(name: "host") {
            upstreamHead.headers.add(name: "Host", value: target.authority)
        }
        requestHead = upstreamHead
        phase = .routing
        let request = HTTPRouteRequest(
            destination: destination, method: head.method.rawValue, url: head.uri,
            userAgent: head.headers.first(name: "user-agent"),
            inboundPort: context.channel.localAddress?.port.map { UInt16(clamping: $0) })
        let loopBound = NIOLoopBound(self, eventLoop: context.eventLoop)
        delegate.route(request, channel: context.channel).hop(to: context.eventLoop).whenComplete { result in
            let handler = loopBound.value
            switch result {
            case .success(let decision):
                handler.handle(decision)
            case .failure(let error):
                handler.handle(.fail(NetworkError(.netPolicyUnavailable, "\(error)"), observer: nil))
            }
        }
    }

    private func handle(_ decision: HTTPRouteDecision) {
        guard case .routing = phase, let context else { return }
        switch decision {
        case .reject(let response, let observer):
            self.observer = observer
            phase = .rejecting
            reject(response, context: context)
        case .fail(let error, let observer):
            self.observer = observer
            badGateway(error, context: context)
        case .forward(let plan):
            observer = plan.observer
            if let existing = upstream, existing.key == plan.reuseKey, existing.keepAlive, existing.channel.isActive {
                use(existing)
                return
            }
            closeUpstream()
            phase = .dialing
            let loopBound = NIOLoopBound(self, eventLoop: context.eventLoop)
            plan.dial().hop(to: context.eventLoop).whenComplete { result in
                let handler = loopBound.value
                guard case .dialing = handler.phase else {
                    if case .success(let channel) = result { channel.close(promise: nil) }
                    return
                }
                switch result {
                case .success(let channel):
                    handler.attachUpstream(channel, key: plan.reuseKey)
                case .failure(let error):
                    guard let context = handler.context else { return }
                    handler.badGateway(
                        (error as? any AetherErrorProtocol) ?? NetworkError(.netConnectionRefused, "\(error)"),
                        context: context)
                }
            }
        }
    }

    private func attachUpstream(_ channel: any Channel, key: String) {
        guard let context else {
            channel.close(promise: nil)
            return
        }
        let relay = HTTPUpstreamRelayHandler(server: self)
        do {
            try channel.pipeline.syncOperations.addHTTPClientHandlers()
            try channel.pipeline.syncOperations.addHandler(relay)
            try channel.syncOptions?.setOption(.autoRead, value: true)
        } catch {
            channel.close(promise: nil)
            badGateway(NetworkError(.netProtocolError, "\(error)"), context: context)
            return
        }
        let upstream = Upstream(key: key, channel: channel, relay: relay)
        self.upstream = upstream
        observer?.upstreamConnected(remoteAddress: channel.remoteAddress?.description)
        use(upstream)
    }

    private func use(_ upstream: Upstream) {
        guard let requestHead, let context else { return }
        phase = .forwarding
        upstream.channel.write(HTTPClientRequestPart.head(requestHead), promise: nil)
        for part in queued {
            switch part {
            case .body(let buffer):
                observer?.transferred(up: buffer.readableBytes, down: 0)
                upstream.channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
            case .end(let trailers):
                upstream.channel.write(HTTPClientRequestPart.end(trailers), promise: nil)
            case .head:
                break
            }
        }
        queued = []
        upstream.channel.flush()
        resumeClientReadIfPossible(context: context)
    }

    private func beginConnect(_ destination: Destination, context: ChannelHandlerContext) {
        phase = .closed
        let channel = context.channel
        let delegate = self.delegate
        let pipeline = context.pipeline.syncOperations
        try? channel.syncOptions?.setOption(.autoRead, value: false)
        let collector = LeftoverCollector()
        do {
            let decoder = try pipeline.handler(type: ByteToMessageHandler<HTTPRequestDecoder>.self)
            try pipeline.addHandler(collector, position: .after(decoder))
            _ = pipeline.removeHandler(decoder)
            _ = pipeline.removeHandler(try pipeline.handler(type: HTTPResponseEncoder.self))
            if let assistant = try? pipeline.handler(type: HTTPServerPipelineHandler.self) {
                _ = pipeline.removeHandler(assistant)
            }
            if let errors = try? pipeline.handler(type: HTTPServerProtocolErrorHandler.self) {
                _ = pipeline.removeHandler(errors)
            }
        } catch {
            context.close(promise: nil)
            return
        }
        pipeline.removeHandler(context: context).assumeIsolated().whenComplete { _ in
            let leftover = collector.buffer.readableBytes > 0 ? collector.buffer : nil
            _ = channel.pipeline.syncOperations.removeHandler(collector)
            delegate.connect(
                destination, channel: channel, initialData: leftover, replier: HTTPConnectReplier(channel: channel))
        }
    }

    // MARK: 上游响应（由 HTTPUpstreamRelayHandler 调用）

    func upstreamResponse(_ part: HTTPClientResponsePart, from relay: HTTPUpstreamRelayHandler) {
        guard let context, let upstream, upstream.relay === relay, case .forwarding = phase else { return }
        switch part {
        case .head(var head):
            responseStarted = true
            observer?.responseStarted(status: Int(head.status.code))
            upstream.keepAlive = head.isKeepAlive
            HTTPHopByHop.strip(&head.headers)
            if !clientKeepAlive {
                head.headers.replaceOrAdd(name: "Connection", value: "close")
            } else if clientVersion == .http1_0 {
                head.headers.replaceOrAdd(name: "Connection", value: "keep-alive")
            }
            context.write(wrapOutboundOut(.head(head)), promise: nil)
        case .body(let buffer):
            observer?.transferred(up: 0, down: buffer.readableBytes)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        case .end(let trailers):
            // 上游提前响应、请求体尚未发完时，上游连接的状态不再可靠，不复用。
            if !upstream.keepAlive || !requestEnded {
                closeUpstream()
            }
            endResponse(trailers: trailers, error: nil, context: context)
        }
    }

    func upstreamReadComplete(from relay: HTTPUpstreamRelayHandler) {
        guard upstream?.relay === relay else { return }
        context?.flush()
    }

    func upstreamClosed(_ relay: HTTPUpstreamRelayHandler) {
        guard let current = upstream, current.relay === relay else { return }
        upstream = nil
        guard case .forwarding = phase, let context else { return }
        if responseEnded { return }
        if responseStarted {
            finish(error: NetworkError(.netConnectionReset, "Upstream closed mid-response"))
            context.close(promise: nil)
        } else {
            badGateway(NetworkError(.netConnectionReset, "Upstream closed before responding"), context: context)
        }
    }

    func upstreamWritabilityChanged(_ relay: HTTPUpstreamRelayHandler) {
        guard upstream?.relay === relay, let context else { return }
        resumeClientReadIfPossible(context: context)
    }

    /// 客户端是否可写（上游一侧据此暂停读取）。
    var clientWritable: Bool {
        context?.channel.isWritable ?? false
    }

    // MARK: 响应与收尾

    private func reject(_ response: HTTPRejectResponse, context: ChannelHandlerContext) {
        switch response {
        case .drop(let timeout):
            let loopBound = NIOLoopBound(context, eventLoop: context.eventLoop)
            dropTimer = context.eventLoop.scheduleTask(in: timeout) {
                loopBound.value.close(promise: nil)
            }
        case .forbidden(let errorPage):
            let body =
                errorPage
                ? "<!doctype html><html><head><meta charset=\"utf-8\"><title>403</title></head><body><h1>403 Forbidden</h1>"
                    + "<p>This request was blocked by a rule in Aether.</p></body></html>"
                : ""
            writeResponse(
                status: .forbidden, contentType: errorPage ? "text/html; charset=utf-8" : nil, body: Array(body.utf8),
                context: context)
        case .tinyGIF:
            writeResponse(status: .ok, contentType: "image/gif", body: TinyGIF.bytes, context: context)
        }
    }

    private func badGateway(_ error: any AetherErrorProtocol, context: ChannelHandlerContext) {
        phase = .rejecting
        let body = "Aether could not complete the request (\(error.code.rawValue)).\n"
        writeResponse(
            status: .badGateway, contentType: "text/plain; charset=utf-8", body: Array(body.utf8),
            context: context, error: error)
    }

    private func writeResponse(
        status: HTTPResponseStatus, contentType: String?, body: [UInt8], context: ChannelHandlerContext,
        error: (any AetherErrorProtocol)? = nil
    ) {
        var headers = HTTPHeaders()
        if let contentType {
            headers.add(name: "Content-Type", value: contentType)
        }
        headers.add(name: "Content-Length", value: "\(body.count)")
        if !clientKeepAlive {
            headers.add(name: "Connection", value: "close")
        }
        responseStarted = true
        observer?.responseStarted(status: Int(status.code))
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: clientVersion, status: status, headers: headers))),
            promise: nil)
        if !body.isEmpty {
            context.write(
                wrapOutboundOut(.body(.byteBuffer(context.channel.allocator.buffer(bytes: body)))), promise: nil)
        }
        endResponse(trailers: nil, error: error, context: context)
    }

    /// 写出响应结束并完成本次交换。
    ///
    /// 必须先更新状态再写：`HTTPServerPipelineHandler` 会在 `.end` 写出时同步交来下一个流水线请求。
    /// 请求体尚未收完时（上游提前响应、拒绝）进入 `.rejecting`，读完并丢弃剩余请求体后再完成。
    private func endResponse(trailers: HTTPHeaders?, error: (any AetherErrorProtocol)?, context: ChannelHandlerContext)
    {
        responseEnded = true
        guard requestEnded || error != nil else {
            phase = .rejecting
            finish(error: nil)
            context.writeAndFlush(wrapOutboundOut(.end(trailers)), promise: nil)
            resumeDrainIfNeeded(context: context)
            return
        }
        finish(error: error)
        requestHead = nil
        queued = []
        let keepAlive = clientKeepAlive && error == nil
        phase = keepAlive ? .idle : .closed
        let write = context.writeAndFlush(wrapOutboundOut(.end(trailers)))
        if keepAlive {
            if pendingRead {
                pendingRead = false
                context.read()
            }
        } else {
            let loopBound = NIOLoopBound(context, eventLoop: context.eventLoop)
            write.whenComplete { _ in loopBound.value.close(promise: nil) }
        }
    }

    private func resumeDrainIfNeeded(context: ChannelHandlerContext) {
        if pendingRead {
            pendingRead = false
            context.read()
        }
    }

    private func respondAndClose(status: HTTPResponseStatus, context: ChannelHandlerContext) {
        phase = .closed
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
        let loopBound = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            loopBound.value.close(promise: nil)
        }
    }

    private func finish(error: (any AetherErrorProtocol)?) {
        let current = observer
        observer = nil
        current?.finished(error: error)
    }

    /// 响应已经写完、请求体随后读完：保持连接则回到空闲并恢复读取，否则关闭客户端连接。
    private func completeExchange(error: (any AetherErrorProtocol)?) {
        finish(error: error)
        guard let context else { return }
        requestHead = nil
        queued = []
        if clientKeepAlive, error == nil {
            phase = .idle
            if pendingRead {
                pendingRead = false
                context.read()
            }
        } else {
            phase = .closed
            context.close(promise: nil)
        }
    }

    private func resumeClientReadIfPossible(context: ChannelHandlerContext) {
        guard pendingRead, case .forwarding = phase, !requestEnded, upstream?.channel.isWritable == true else {
            return
        }
        pendingRead = false
        context.read()
    }

    private func closeUpstream() {
        if let upstream {
            self.upstream = nil
            upstream.channel.close(promise: nil)
        }
    }

    // MARK: ChannelDuplexHandler

    public func read(context: ChannelHandlerContext) {
        switch phase {
        case .idle:
            context.read()
        case .forwarding where !requestEnded && upstream?.channel.isWritable == true:
            context.read()
        case .rejecting where !requestEnded:
            context.read()
        default:
            pendingRead = true
        }
    }

    public func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            upstream?.relay.resume()
        }
        context.fireChannelWritabilityChanged()
    }

    public func channelInactive(context: ChannelHandlerContext) {
        dropTimer?.cancel()
        closeUpstream()
        if case .closed = phase {
        } else if observer != nil {
            finish(error: responseEnded ? nil : NetworkError(.netConnectionReset, "Client closed the connection"))
        }
        phase = .closed
        context.fireChannelInactive()
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            // 客户端不再发送请求：当前交换完成后关闭（空闲时立即关闭）。
            clientKeepAlive = false
            if case .idle = phase {
                context.close(promise: nil)
            }
        }
        context.fireUserInboundEventTriggered(event)
    }

    public func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if error is HTTPParserError, case .idle = phase {
            respondAndClose(status: .badRequest, context: context)
            return
        }
        context.close(promise: nil)
    }
}

@available(*, unavailable)
extension HTTPProxyServerHandler: Sendable {}

/// 上游一侧：把响应交给客户端一侧，客户端不可写时暂停读取。
final class HTTPUpstreamRelayHandler: ChannelDuplexHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    private weak var server: HTTPProxyServerHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    init(server: HTTPProxyServerHandler) {
        self.server = server
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        server?.upstreamResponse(unwrapInboundIn(data), from: self)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        server?.upstreamReadComplete(from: self)
    }

    func channelInactive(context: ChannelHandlerContext) {
        server?.upstreamClosed(self)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        server?.upstreamWritabilityChanged(self)
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if server?.clientWritable ?? false {
            context.read()
        } else {
            pendingRead = true
        }
    }

    func resume() {
        if pendingRead, let context {
            pendingRead = false
            context.read()
        }
    }
}

@available(*, unavailable)
extension HTTPUpstreamRelayHandler: Sendable {}

/// 移除请求解码器时接住它转发出来的剩余字节（`CONNECT` 之后客户端立即发送的数据）。
private final class LeftoverCollector: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    var buffer = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
    }
}

@available(*, unavailable)
extension LeftoverCollector: Sendable {}
