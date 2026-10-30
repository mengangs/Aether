import NIOCore
import NIOHTTP1
import NIOPosix

/// 测试用 HTTP/1.1 源站（回环地址；互通测试中替代 docs/13 §3.1 的 nginx）。每个响应带 `Connection: close`。
///
/// - `GET /bytes/<n>`：n 字节的确定内容（第 i 字节为 `HTTPTestOrigin.byte(at: i)`），按可写性分块发送，
///   不在内存中整体生成；
/// - `GET /generate_204`：`204`；
/// - `GET /abort/<n>`：声明 n 字节，发送前一半后关闭连接（模拟服务端中途断开）；
/// - 其它路径：`404`。
public final class HTTPTestOrigin: Sendable {
    public let server: LoopbackTCPServer

    private init(server: LoopbackTCPServer) {
        self.server = server
    }

    public var port: Int { server.port }

    /// 内容的第 `index` 个字节。
    public static func byte(at index: Int) -> UInt8 {
        UInt8(index % 251)
    }

    public static func start(group: any EventLoopGroup) async throws -> HTTPTestOrigin {
        let server = try await LoopbackTCPServer.start(
            group: group, childOptions: { $0.childChannelOption(.allowRemoteHalfClosure, value: false) },
            childInitializer: { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(OriginHandler())
                }
            })
        return HTTPTestOrigin(server: server)
    }

    public func close() async throws {
        try await server.close()
    }
}

private final class OriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    static let chunkSize = 64 * 1024
    /// 周期为 251 的内容，切片即可得到任意偏移处的一块。
    static let pattern: [UInt8] = (0..<(chunkSize + 251)).map { HTTPTestOrigin.byte(at: $0) }

    private var uri = ""
    /// 正在发送的正文：下一个偏移、要发送到的位置、声明的总长度。
    private var sending: (offset: Int, stop: Int, total: Int)?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            uri = head.uri
        case .body:
            break
        case .end:
            respond(context: context)
        }
    }

    private func respond(context: ChannelHandlerContext) {
        let parts = uri.split(separator: "/").map(String.init)
        if parts == ["generate_204"] {
            writeHead(context: context, status: .noContent, length: 0)
            finish(context: context)
        } else if parts.count == 2, parts[0] == "bytes" || parts[0] == "abort", let count = Int(parts[1]), count >= 0 {
            writeHead(context: context, status: .ok, length: count)
            sending = (0, parts[0] == "abort" ? count / 2 : count, count)
            pump(context: context)
        } else {
            writeHead(context: context, status: .notFound, length: 0)
            finish(context: context)
        }
    }

    private func writeHead(context: ChannelHandlerContext, status: HTTPResponseStatus, length: Int) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: String(length))
        headers.add(name: "Connection", value: "close")
        context.write(
            wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers))), promise: nil)
    }

    /// 可写时继续发送下一块。写入与 flush 可能同步触发可写性变化并重入：重入时只做标记，由外层循环继续，
    /// 保证同一时刻只有一处在推进偏移。
    private var pumping = false
    private var pumpRequested = false

    private func pump(context: ChannelHandlerContext) {
        guard !pumping else {
            pumpRequested = true
            return
        }
        pumping = true
        defer { pumping = false }
        repeat {
            pumpRequested = false
            while let state = sending, context.channel.isWritable {
                guard state.offset < state.stop else {
                    sending = nil
                    if state.stop < state.total {
                        context.flush()
                        context.close(promise: nil)
                    } else {
                        finish(context: context)
                    }
                    return
                }
                let count = min(Self.chunkSize, state.stop - state.offset)
                sending = (state.offset + count, state.stop, state.total)
                let start = state.offset % 251
                let buffer = context.channel.allocator.buffer(bytes: Self.pattern[start..<(start + count)])
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            }
            context.flush()
        } while pumpRequested || (sending != nil && context.channel.isWritable)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if sending != nil, context.channel.isWritable {
            pump(context: context)
        }
        context.fireChannelWritabilityChanged()
    }

    private func finish(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}
