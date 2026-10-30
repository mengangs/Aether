import AetherFoundation
import Crypto
import Foundation
import NIOCore
import NIOWebSocket

/// WebSocket 传输参数（docs/04 §5.4、06 §8.5）。
public struct WebSocketClientOptions: Sendable, Hashable {
    public struct Header: Sendable, Hashable {
        public var name: String
        public var value: String

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// `ws-path`，可含查询串；不以 `/` 开头时补上。
    public var path: String
    /// `ws-headers`。其中的 `Host` 覆盖默认的 Host；升级所需的头（`Upgrade`、`Connection`、`Sec-WebSocket-*`）忽略。
    public var headers: [Header]

    public init(path: String = "/", headers: [Header] = []) {
        self.path = path
        self.headers = headers
    }

    /// 请求行中的路径。
    var requestPath: String {
        path.hasPrefix("/") ? path : "/" + path
    }

    /// `Host` 头：`ws-headers` 中的 Host → TLS 的自定义 SNI → 服务器名（非默认端口时附端口，IPv6 加方括号）。
    func hostHeader(serverHost: String, port: UInt16, tls: TLSClientOptions?) -> String {
        if let host = headers.first(where: { $0.name.caseInsensitiveCompare("Host") == .orderedSame }) {
            return host.value
        }
        if case .custom(let name)? = tls?.serverName {
            return name
        }
        let defaultPort: UInt16 = tls == nil ? 80 : 443
        let host = serverHost.contains(":") ? "[\(serverHost)]" : serverHost
        return port == defaultPort ? host : "\(host):\(port)"
    }
}

/// WebSocket 传输（RFC 6455，docs/06 §8.5）：在已连接（且已完成 TLS，若有）的 Channel 上发起客户端升级，
/// 之后应用层载荷以二进制帧收发：
///
/// - 发出的帧带客户端掩码，单帧载荷最多 `WebSocketTransport.maxOutgoingFramePayload`，更大的写入拆成多帧；
/// - 收到的帧载荷最多 `WebSocketTransport.maxIncomingFrameSize`（解码缓冲的上限），超出即以 `NET-032` 关闭；
///   二进制、文本与续帧都按字节流交出，`ping` 回复 `pong`，`close` 回复 `close` 后关闭连接；
/// - WebSocket 没有半关闭：输出方向的关闭（`close(mode: .output)`）被忽略，连接在对端关闭、
///   完全关闭或空闲超时时结束；完全关闭时先发送 `close` 帧。
///
/// 升级响应不是 `101` 时以 `NET-030`（附状态码）失败；`Upgrade` 或 `Sec-WebSocket-Accept` 不符时以 `NET-032` 失败。
/// 暂不支持 early data。
public enum WebSocketTransport {
    /// 收到的单帧载荷上限 128 KiB（常见服务端每帧 ≤ 8 KiB；与每流读缓冲同一量级，docs/02 §6）。
    public static let maxIncomingFrameSize = 128 * 1024
    /// 发出的单帧载荷上限 16 KiB（多数服务端默认接受的帧大小）。
    public static let maxOutgoingFramePayload = 16 * 1024
    /// 升级响应头上限 16 KiB。
    static let maxResponseHeaderBytes = 16 * 1024

    /// 完成升级并装好帧编解码。超过 `deadline` 时以 `NET-002` 失败并关闭连接。
    public static func upgrade(
        on channel: any Channel, serverHost: String, port: UInt16, tls: TLSClientOptions?,
        options: WebSocketClientOptions, deadline: NIODeadline
    ) -> EventLoopFuture<any Channel> {
        let eventLoop = channel.eventLoop
        let promise = eventLoop.makePromise(of: (any Channel).self)
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let handler = WebSocketUpgradeHandler(
            request: request(
                key: key, host: options.hostHeader(serverHost: serverHost, port: port, tls: tls), options: options),
            expectedAccept: acceptValue(forKey: key), promise: promise)
        do {
            try channel.pipeline.syncOperations.addHandler(handler)
        } catch {
            channel.close(promise: nil)
            return eventLoop.makeFailedFuture(NetworkError(.netProtocolError, "\(error)"))
        }
        let timer = eventLoop.scheduleTask(deadline: deadline) {
            promise.fail(NetworkError(.netConnectTimeout, "WebSocket upgrade timed out"))
            channel.close(promise: nil)
        }
        promise.futureResult.whenComplete { _ in timer.cancel() }
        return promise.futureResult
    }

    /// 升级请求（头值中的 CR、LF 去掉，防止注入额外的头）。
    static func request(key: String, host: String, options: WebSocketClientOptions) -> String {
        // 按 Unicode 标量过滤："\r\n" 在 Swift 中是一个 Character，按 Character 比较会漏掉。
        func clean(_ text: String) -> String {
            String(String.UnicodeScalarView(text.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
        }
        var lines = [
            "GET \(clean(options.requestPath)) HTTP/1.1", "Host: \(clean(host))", "Upgrade: websocket",
            "Connection: Upgrade", "Sec-WebSocket-Key: \(key)", "Sec-WebSocket-Version: 13",
        ]
        let reserved: Set<String> = [
            "host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions",
        ]
        for header in options.headers where !reserved.contains(header.name.lowercased()) {
            lines.append("\(clean(header.name)): \(clean(header.value))")
        }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    /// `Sec-WebSocket-Accept` 的期望值（RFC 6455 §4.2.2）。
    static func acceptValue(forKey key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        return Data(digest).base64EncodedString()
    }
}

/// 发送升级请求、读取并校验响应头，成功后换成帧编解码：
/// `[PendingBytesReplayHandler]`（响应头之后紧跟的字节）→ 帧解码 → 帧编码 → `WebSocketStreamHandler`。
final class WebSocketUpgradeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: String
    private let expectedAccept: String
    private let promise: EventLoopPromise<any Channel>
    private var buffer = ByteBuffer()
    private var done = false

    init(request: String, expectedAccept: String, promise: EventLoopPromise<any Channel>) {
        self.request = request
        self.expectedAccept = expectedAccept
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
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
        guard let end = HTTPConnectHandshakeHandler.headerEnd(in: view) else {
            if buffer.readableBytes > WebSocketTransport.maxResponseHeaderBytes {
                fail(context: context, NetworkError(.netProtocolError, "WebSocket upgrade response header too large"))
            }
            return
        }
        guard let headerText = buffer.readString(length: end - view.startIndex) else { return }
        let lines = headerText.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), let status = Int(parts[1]) else {
            fail(context: context, NetworkError(.netProtocolError, "Malformed WebSocket upgrade response"))
            return
        }
        guard status == 101 else {
            fail(context: context, NetworkError(.netProxyHandshakeFailed, "WebSocket upgrade answered \(status)"))
            return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["upgrade"]?.lowercased() == "websocket", headers["sec-websocket-accept"] == expectedAccept else {
            fail(context: context, NetworkError(.netProtocolError, "WebSocket upgrade response failed validation"))
            return
        }
        done = true
        let channel = context.channel
        ChannelTuning.stopReading(channel)
        do {
            var handlers: [any ChannelHandler] = []
            if buffer.readableBytes > 0 {
                handlers.append(PendingBytesReplayHandler(pending: buffer))
            }
            handlers.append(
                ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: WebSocketTransport.maxIncomingFrameSize)))
            handlers.append(WebSocketFrameEncoder())
            handlers.append(WebSocketStreamHandler())
            try context.pipeline.syncOperations.addHandlers(handlers, position: .after(self))
        } catch {
            fail(context: context, NetworkError(.netProtocolError, "\(error)"))
            return
        }
        buffer = ByteBuffer()
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        promise.succeed(channel)
    }

    private func fail(context: ChannelHandlerContext, _ error: NetworkError) {
        done = true
        promise.fail(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !done {
            done = true
            promise.fail(NetworkError(.netConnectionReset, "Server closed the connection during the WebSocket upgrade"))
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
extension WebSocketUpgradeHandler: Sendable {}

/// 帧 ↔ 字节流（见 `WebSocketTransport` 的说明）。
final class WebSocketStreamHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = WebSocketFrame

    private var sentClose = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .text, .continuation:
            let payload = frame.unmaskedData
            if payload.readableBytes > 0 {
                context.fireChannelRead(wrapInboundOut(payload))
            }
        case .ping:
            guard !sentClose else { return }
            let pong = WebSocketFrame(fin: true, opcode: .pong, maskKey: .random(), data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)
        case .pong:
            break
        case .connectionClose:
            // 回复同一状态码（若有）后关闭。
            var payload = frame.unmaskedData
            sendClose(context: context, data: payload.readSlice(length: min(2, payload.readableBytes)))
            context.close(promise: nil)
        default:
            context.fireErrorCaught(NetworkError(.netProtocolError, "Unexpected WebSocket opcode \(frame.opcode)"))
            context.close(promise: nil)
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buffer = unwrapOutboundIn(data)
        guard !sentClose else {
            promise?.fail(ChannelError.outputClosed)
            return
        }
        while buffer.readableBytes > WebSocketTransport.maxOutgoingFramePayload {
            if let slice = buffer.readSlice(length: WebSocketTransport.maxOutgoingFramePayload) {
                let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: slice)
                context.write(wrapOutboundOut(frame), promise: nil)
            }
        }
        let frame = WebSocketFrame(fin: true, opcode: .binary, maskKey: .random(), data: buffer)
        context.write(wrapOutboundOut(frame), promise: promise)
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        switch mode {
        case .output:
            // WebSocket 没有半关闭：忽略输出方向的关闭，连接在对端关闭或空闲超时时结束。
            promise?.succeed(())
        case .all:
            if context.channel.isActive {
                var status = context.channel.allocator.buffer(capacity: 2)
                status.write(webSocketErrorCode: .normalClosure)
                sendClose(context: context, data: status)
            }
            context.close(mode: mode, promise: promise)
        default:
            context.close(mode: mode, promise: promise)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if error is NIOWebSocketError || error is ByteToMessageDecoderError {
            context.fireErrorCaught(NetworkError(.netProtocolError, "WebSocket: \(error)"))
            context.close(promise: nil)
        } else {
            context.fireErrorCaught(error)
        }
    }

    /// 发送一次 `close` 帧（之后不再发送数据帧）。
    private func sendClose(context: ChannelHandlerContext, data: ByteBuffer?) {
        guard !sentClose else { return }
        sentClose = true
        let payload = data ?? context.channel.allocator.buffer(capacity: 0)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, maskKey: .random(), data: payload)
        context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
    }
}

@available(*, unavailable)
extension WebSocketStreamHandler: Sendable {}
