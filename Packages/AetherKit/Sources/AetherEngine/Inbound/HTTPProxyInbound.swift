import AetherHTTP
import AetherOutbound
import NIOCore
import NIOHTTP1
import NIOPosix

/// HTTP 代理入站（docs/06 §5.2）：作为系统 HTTP / HTTPS 代理监听 `127.0.0.1:6171`。
///
/// 每个连接的管线为 keep-alive 空闲超时（60 秒，docs/06 §6.1）、请求解码器（剩余字节转发给下一个 Handler，
/// 供 `CONNECT` 使用）、响应编码器、流水线辅助（`HTTPServerPipelineHandler`）、协议错误处理（回复 400）与
/// `HTTPProxyServerHandler`。
public final class HTTPProxyInbound: Sendable {
    public static let defaultPort = 6171

    public let channel: any Channel

    private init(channel: any Channel) {
        self.channel = channel
    }

    public var port: Int {
        channel.localAddress?.port ?? 0
    }

    public static func start(
        on eventLoop: any EventLoop, host: String = "127.0.0.1", port: Int = HTTPProxyInbound.defaultPort,
        delegate: any HTTPProxyDelegate, keepAliveTimeout: TimeAmount = EngineTimeouts.default.httpKeepAlive
    ) -> EventLoopFuture<HTTPProxyInbound> {
        ChannelTuning.configure(ServerBootstrap(group: eventLoop))
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    let pipeline = child.pipeline.syncOperations
                    try pipeline.addHandler(IdleTimeoutHandler(timeout: keepAliveTimeout))
                    try pipeline.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)))
                    try pipeline.addHandler(HTTPResponseEncoder())
                    // 流水线请求：后续请求在当前响应结束前由它缓存，并暂停读取。
                    try pipeline.addHandler(HTTPServerPipelineHandler())
                    try pipeline.addHandler(HTTPServerProtocolErrorHandler())
                    try pipeline.addHandler(HTTPProxyServerHandler(delegate: delegate))
                }
            }
            .bind(host: host, port: port)
            .map { HTTPProxyInbound(channel: $0) }
    }

    public func close() -> EventLoopFuture<Void> {
        channel.close()
    }
}
