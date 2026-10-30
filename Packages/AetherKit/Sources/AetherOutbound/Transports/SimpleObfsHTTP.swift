import AetherFoundation
import Foundation
import NIOCore

/// simple-obfs http 的参数（docs/04 §5.5 `obfs-host`、`obfs-uri`）。
public struct SimpleObfsHTTPOptions: Sendable, Hashable {
    /// 为 nil 时用服务器地址。
    public var host: String?
    public var uri: String

    public init(host: String? = nil, uri: String = "/") {
        self.host = host
        self.uri = uri
    }
}

/// simple-obfs http（docs/06 §8.5，与 simple-obfs `obfs_http.c` 一致）：
///
/// - 第一次写入伪装成 `GET <uri>` 请求（`Host`：`obfs-host` 或服务器地址，非 80 端口时附端口；带
///   `Upgrade: websocket`、随机 `Sec-WebSocket-Key`，`Content-Length` 为数据长度），数据作为请求体；之后原样发送；
/// - 收到的数据先跳过一次 HTTP 响应头（上限 16 KiB，超出以 `NET-032` 关闭），之后原样交出。
final class SimpleObfsHTTPHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let maxResponseHeaderBytes = 16 * 1024

    private let host: String
    private let uri: String
    private var sentRequest = false
    private var skippedResponse = false
    private var header = ByteBuffer()

    init(options: SimpleObfsHTTPOptions, serverHost: String, serverPort: UInt16) {
        let name = options.host ?? serverHost
        let bracketed = name.contains(":") ? "[\(name)]" : name
        host = serverPort == 80 ? bracketed : "\(bracketed):\(serverPort)"
        uri = options.uri.hasPrefix("/") ? options.uri : "/" + options.uri
    }

    /// 请求头（不含请求体）。
    static func requestHeader(host: String, uri: String, contentLength: Int) -> String {
        let key = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64EncodedString()
        let agent = "curl/7.\(Int.random(in: 0..<51)).\(Int.random(in: 0..<2))"
        return "GET \(uri) HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: \(agent)\r\nUpgrade: websocket\r\n"
            + "Connection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nContent-Length: \(contentLength)\r\n\r\n"
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        guard !sentRequest else {
            context.write(data, promise: promise)
            return
        }
        sentRequest = true
        var body = unwrapOutboundIn(data)
        var request = context.channel.allocator.buffer(
            string: Self.requestHeader(host: host, uri: uri, contentLength: body.readableBytes))
        request.writeBuffer(&body)
        context.write(wrapOutboundOut(request), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !skippedResponse else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        header.writeBuffer(&incoming)
        guard let end = HTTPConnectHandshakeHandler.headerEnd(in: header.readableBytesView) else {
            if header.readableBytes > Self.maxResponseHeaderBytes {
                context.fireErrorCaught(NetworkError(.netProtocolError, "simple-obfs response header too large"))
                context.close(promise: nil)
            }
            return
        }
        skippedResponse = true
        header.moveReaderIndex(to: end)
        let rest = header
        header = ByteBuffer()
        if rest.readableBytes > 0 {
            context.fireChannelRead(wrapInboundOut(rest))
        }
    }
}

@available(*, unavailable)
extension SimpleObfsHTTPHandler: Sendable {}
