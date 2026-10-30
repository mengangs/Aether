import AetherFoundation
import AetherOutbound
import Foundation
import NIOCore
import NIOHTTP1

/// 经出站连接器的 HTTP/1.1 GET（隧道下载外部资源，docs/11 §5.3）。
///
/// - 每次请求新建连接（`Connection: close`）；HTTPS 在出站连接上再做一层 TLS（完整验证）；
/// - 正文支持 `Content-Length`、`chunked` 与读到连接关闭为止三种形式（NIOHTTP1 解码），不请求压缩编码；
/// - 跟随最多 `maxRedirects` 次 301 / 302 / 303 / 307 / 308（`Location` 可为相对地址），拒绝 HTTPS 降级到 HTTP；
/// - 正文超过 `limit` 时立即关闭连接并以 `RES-010` 失败，连接在应答结束前断开以 `NET-004` 失败；
/// - 整个过程（含重定向）`timeout` 内未完成以 `NET-002` 失败。
///
/// 其它状态码（含 304）照常返回，由调用方解释。`dial` 返回的连接必须在 `eventLoop` 上。
public enum HTTPFetch {
    public struct Response: Sendable {
        public var status: Int
        public var headers: HTTPHeaders
        public var body: [UInt8]
        /// 跟随重定向后的最终 URL。
        public var url: String

        public func header(_ name: String) -> String? {
            headers.first(name: name)
        }
    }

    /// 建立到目标的出站连接（未加 TLS）；第二个参数为整个下载的截止时间。
    public typealias Dial = @Sendable (Destination, NIODeadline) -> EventLoopFuture<any Channel>

    public static let defaultTimeout = TimeAmount.seconds(20)
    public static let defaultMaxRedirects = 5

    public static func get(
        _ url: String, headers: [(String, String)] = [], limit: Int, timeout: TimeAmount = defaultTimeout,
        maxRedirects: Int = defaultMaxRedirects, tls: TLSClientOptions = TLSClientOptions(),
        on eventLoop: any EventLoop, dial: @escaping Dial
    ) -> EventLoopFuture<Response> {
        let operation = FetchOperation(
            headers: headers, limit: limit, deadline: .now() + timeout, redirects: maxRedirects, tls: tls,
            eventLoop: eventLoop, dial: dial)
        eventLoop.execute { operation.start(url) }
        return operation.promise.futureResult
    }
}

/// 一次下载（含重定向）的状态；只在 `eventLoop` 上访问。
private final class FetchOperation: @unchecked Sendable {
    let headers: [(String, String)]
    let limit: Int
    let deadline: NIODeadline
    let tls: TLSClientOptions
    let eventLoop: any EventLoop
    let dial: HTTPFetch.Dial
    let promise: EventLoopPromise<HTTPFetch.Response>
    private var redirectsLeft: Int
    private var channel: (any Channel)?
    private var finished = false
    private var timer: Scheduled<Void>?

    init(
        headers: [(String, String)], limit: Int, deadline: NIODeadline, redirects: Int, tls: TLSClientOptions,
        eventLoop: any EventLoop, dial: @escaping HTTPFetch.Dial
    ) {
        self.headers = headers
        self.limit = limit
        self.deadline = deadline
        self.tls = tls
        self.eventLoop = eventLoop
        self.dial = dial
        redirectsLeft = redirects
        promise = eventLoop.makePromise(of: HTTPFetch.Response.self)
    }

    func start(_ url: String) {
        timer = eventLoop.scheduleTask(deadline: deadline) { [self] in
            finish(.failure(NetworkError(.netConnectTimeout, "Download did not finish in time")))
        }
        request(url)
    }

    private func finish(_ result: Result<HTTPFetch.Response, any Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        channel?.close(promise: nil)
        channel = nil
        promise.completeWith(result)
    }

    private func request(_ url: String) {
        guard let target = HTTPProbe.Target(url), let destination = target.destination else {
            finish(.failure(ResourceError(.resDownloadFailed, "Invalid URL \(url)")))
            return
        }
        var connected = dial(destination, deadline)
        if target.secure {
            let tls = self.tls
            let deadline = self.deadline
            connected = connected.flatMap { channel in
                TLSTransport.handshake(on: channel, serverHost: target.host, options: tls, deadline: deadline)
                    .flatMapErrorThrowing { error in
                        channel.close(promise: nil)
                        throw error
                    }
            }
        }
        connected.hop(to: eventLoop).whenComplete { [self] result in
            switch result {
            case .failure(let error):
                finish(.failure(error))
            case .success(let channel):
                guard !finished else {
                    channel.close(promise: nil)
                    return
                }
                self.channel = channel
                do {
                    try send(target, url: url, on: channel)
                } catch {
                    finish(.failure(NetworkError(.netProtocolError, "\(error)")))
                }
            }
        }
    }

    private func send(_ target: HTTPProbe.Target, url: String, on channel: any Channel) throws {
        try channel.pipeline.syncOperations.addHTTPClientHandlers()
        try channel.pipeline.syncOperations.addHandler(
            FetchResponseReader(limit: limit) { [self] event in handle(event, url: url, secure: target.secure) })
        try channel.syncOptions?.setOption(.autoRead, value: true)
        channel.read()
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: target.path)
        head.headers.add(name: "Host", value: target.hostHeader)
        for (name, value) in headers {
            head.headers.add(name: name, value: value)
        }
        if !head.headers.contains(name: "User-Agent") {
            head.headers.add(name: "User-Agent", value: "Aether")
        }
        head.headers.add(name: "Accept", value: "*/*")
        head.headers.add(name: "Accept-Encoding", value: "identity")
        head.headers.add(name: "Connection", value: "close")
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
    }

    private func handle(_ event: FetchResponseReader.Event, url: String, secure: Bool) {
        guard !finished else { return }
        switch event {
        case .complete(let head, let body):
            finish(
                .success(HTTPFetch.Response(status: Int(head.status.code), headers: head.headers, body: body, url: url))
            )
        case .redirect(let location):
            redirect(from: url, to: location, secure: secure)
        case .failed(let error):
            finish(.failure(error))
        }
    }

    private func redirect(from url: String, to location: String, secure: Bool) {
        channel?.close(promise: nil)
        channel = nil
        guard redirectsLeft > 0 else {
            finish(.failure(ResourceError(.resDownloadFailed, "Too many redirects")))
            return
        }
        redirectsLeft -= 1
        guard let next = URL(string: location, relativeTo: URL(string: url))?.absoluteURL.absoluteString,
            let scheme = URLComponents(string: next)?.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else {
            finish(.failure(ResourceError(.resDownloadFailed, "Invalid redirect location \(location)")))
            return
        }
        guard !(secure && scheme == "http") else {
            finish(.failure(ResourceError(.resDownloadFailed, "Redirect from HTTPS to HTTP refused")))
            return
        }
        request(next)
    }
}

/// 收集一个应答：重定向在收到响应头时即回调（不读正文），正文超过上限或在应答结束前断开时回调失败。只回调一次。
private final class FetchResponseReader: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    enum Event {
        case complete(HTTPResponseHead, [UInt8])
        case redirect(String)
        case failed(any Error)
    }

    private let limit: Int
    private let callback: (Event) -> Void
    private var head: HTTPResponseHead?
    private var body: [UInt8] = []
    private var done = false

    init(limit: Int, callback: @escaping (Event) -> Void) {
        self.limit = limit
        self.callback = callback
    }

    private func finish(_ event: Event) {
        guard !done else { return }
        done = true
        callback(event)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        switch unwrapInboundIn(data) {
        case .head(let head):
            if [301, 302, 303, 307, 308].contains(head.status.code), let location = head.headers.first(name: "Location")
            {
                finish(.redirect(location))
                return
            }
            // 1xx 信息应答之后还有最终应答。
            guard head.status.code >= 200 else { return }
            self.head = head
            if let length = head.headers.first(name: "Content-Length").flatMap(Int.init), length > limit {
                finish(.failed(ResourceError(.resTooLarge, "Resource exceeds \(limit) bytes")))
            }
        case .body(let buffer):
            guard body.count + buffer.readableBytes <= limit else {
                finish(.failed(ResourceError(.resTooLarge, "Resource exceeds \(limit) bytes")))
                return
            }
            body += buffer.readableBytesView
        case .end:
            guard let head else { return }
            finish(.complete(head, body))
        }
    }

    /// 出站连接允许对端半关闭：解码器先处理 `inputClosed`（读到关闭为止的正文在此结束），之后仍未完成即为截断。
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            finish(.failed(NetworkError(.netConnectionReset, "Connection closed before the response completed")))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(.failed(NetworkError(.netConnectionReset, "Connection closed before the response completed")))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        finish(.failed(NetworkError(.netProtocolError, "Invalid HTTP response: \(error)")))
        context.close(promise: nil)
    }
}
