import AetherFoundation
import AetherOutbound
import Foundation
import NIOCore

/// 经出站连接器的测速请求（docs/06 §9.2）：`GET url`、`Connection: close`，延迟 = 从开始建立连接到收到响应
/// 状态行的时间；任意 2xx / 3xx 视为成功，其它状态码以 `NET-030` 失败；`timeout` 内未完成以 `NET-002` 失败。
/// HTTPS 的测速 URL 在出站连接上再做一层 TLS（完整验证）。只读响应的状态行（上限 8 KiB），读到即关闭连接。
public enum HTTPProbe {
    /// 解析后的测速 URL。
    public struct Target: Sendable, Hashable {
        public var secure: Bool
        public var host: String
        public var port: UInt16
        /// 请求行中的路径（含查询串）。
        public var path: String

        /// 只接受 `http` / `https` 的绝对 URL。
        public init?(_ url: String) {
            guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
                scheme == "http" || scheme == "https", let host = components.host, !host.isEmpty
            else { return nil }
            secure = scheme == "https"
            self.host = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            port = UInt16(components.port ?? (secure ? 443 : 80))
            let rawPath = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
            path = rawPath + (components.percentEncodedQuery.map { "?" + $0 } ?? "")
        }

        var destination: Destination? {
            Destination(host: host, port: port)
        }

        var hostHeader: String {
            let name = host.contains(":") ? "[\(host)]" : host
            return port == (secure ? 443 : 80) ? name : "\(name):\(port)"
        }
    }

    static let maxStatusLineBytes = 8 * 1024

    /// 测一次延迟（毫秒）。`now` 用于计时（测试注入）。
    public static func measure(
        _ target: Target, through connector: any OutboundConnector, context: DialContext, timeout: TimeAmount,
        now: @escaping @Sendable () -> NIODeadline = { .now() }
    ) -> EventLoopFuture<Int> {
        let eventLoop = context.eventLoop
        guard let destination = target.destination else {
            return eventLoop.makeFailedFuture(NetworkError(.netPolicyUnavailable, "Invalid test URL host"))
        }
        let started = now()
        let promise = eventLoop.makePromise(of: Int.self)
        let timer = eventLoop.scheduleTask(in: timeout) {
            promise.fail(NetworkError(.netConnectTimeout, "Latency test timed out"))
        }
        let channelBox = NIOLoopBoundBox<(any Channel)?>(nil, eventLoop: eventLoop)
        promise.futureResult.whenComplete { _ in
            timer.cancel()
            eventLoop.execute { channelBox.value?.close(promise: nil) }
        }
        var connected = connector.connect(to: destination, context: context)
        if target.secure {
            connected = connected.flatMap { channel in
                var options = TLSClientOptions()
                options.serverName = .server
                return TLSTransport.handshake(
                    on: channel, serverHost: target.host, options: options, deadline: context.deadline
                ).flatMapErrorThrowing { error in
                    channel.close(promise: nil)
                    throw error
                }
            }
        }
        connected.hop(to: eventLoop).whenComplete { result in
            switch result {
            case .failure(let error):
                promise.fail(error)
            case .success(let channel):
                channelBox.value = channel
                let reader = StatusLineReader { status in
                    guard let status else {
                        promise.fail(NetworkError(.netConnectionReset, "Connection closed before the status line"))
                        return
                    }
                    guard (200..<400).contains(status) else {
                        promise.fail(NetworkError(.netProxyHandshakeFailed, "Test URL answered \(status)"))
                        return
                    }
                    let elapsed = now() - started
                    promise.succeed(max(0, Int(elapsed.nanoseconds / 1_000_000)))
                }
                do {
                    try channel.pipeline.syncOperations.addHandler(reader)
                    try channel.syncOptions?.setOption(.autoRead, value: true)
                    channel.read()
                    let request =
                        "GET \(target.path) HTTP/1.1\r\nHost: \(target.hostHeader)\r\nUser-Agent: Aether\r\n"
                        + "Accept: */*\r\nConnection: close\r\n\r\n"
                    channel.writeAndFlush(channel.allocator.buffer(string: request), promise: nil)
                } catch {
                    promise.fail(NetworkError(.netProtocolError, "\(error)"))
                }
            }
        }
        return promise.futureResult
    }
}

/// 读出响应状态行中的状态码后回调一次；连接在此之前结束时回调 nil。
private final class StatusLineReader: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let completion: (Int?) -> Void
    private var buffer = ByteBuffer()
    private var done = false

    init(completion: @escaping (Int?) -> Void) {
        self.completion = completion
    }

    private func finish(_ status: Int?) {
        guard !done else { return }
        done = true
        completion(status)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else { return }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        let view = buffer.readableBytesView
        guard let lineEnd = view.firstIndex(of: 10) else {
            if buffer.readableBytes > HTTPProbe.maxStatusLineBytes {
                finish(nil)
            }
            return
        }
        let line = String(decoding: view[view.startIndex..<lineEnd], as: UTF8.self)
        let parts = line.split(separator: " ")
        if parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) {
            finish(status)
        } else {
            finish(nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            finish(nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        finish(nil)
    }
}
