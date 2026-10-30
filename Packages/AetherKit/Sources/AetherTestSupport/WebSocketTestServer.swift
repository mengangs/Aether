import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket

/// 测试用 WebSocket 服务（回环地址）：用 NIO 的服务端升级器校验客户端的升级请求，之后按 `Behavior` 处理帧。
public final class WebSocketTestServer: Sendable {
    public enum Behavior: Sendable {
        /// 回显每个数据帧的载荷。
        case echo
        /// 升级后先发一个 `ping`，再回显。
        case pingThenEcho
        /// 回显第一帧后发送 `close`。
        case closeAfterFirstEcho
        /// 升级后发送一个给定大小的二进制帧，再回显。
        case sendFrame(size: Int)
        /// 拒绝升级，以给定状态码回复。
        case reject(status: Int)
        /// 升级后把帧载荷作为字节流交给 `make()` 生成的 Handler，它写出的字节以二进制帧发回（如代理协议的服务端）。
        case forward(@Sendable () -> any ChannelHandler)
    }

    /// 收到的升级请求。
    public struct Request: Sendable {
        public var uri: String
        /// 头名小写。
        public var headers: [String: String]
    }

    struct State {
        var requests: [Request] = []
        var pongs = 0
        var largestClientFrame = 0
        var clientCloses = 0
    }

    public let server: LoopbackTCPServer
    private let state: NIOLockedValueBox<State>

    private init(server: LoopbackTCPServer, state: NIOLockedValueBox<State>) {
        self.server = server
        self.state = state
    }

    public var requests: [Request] { state.withLockedValue { $0.requests } }
    public var pongCount: Int { state.withLockedValue { $0.pongs } }
    /// 客户端发来的最大帧载荷。
    public var largestClientFrame: Int { state.withLockedValue { $0.largestClientFrame } }
    /// 收到客户端 `close` 帧的次数。
    public var clientCloseCount: Int { state.withLockedValue { $0.clientCloses } }

    /// 启动服务。`prefix` 在 HTTP 管线之前装入 Handler（如 TLS）。
    public static func start(
        group: any EventLoopGroup, behavior: Behavior = .echo,
        prefix: @escaping @Sendable (any Channel) throws -> Void = { _ in }
    ) async throws -> WebSocketTestServer {
        let state = NIOLockedValueBox(State())
        let server = try await LoopbackTCPServer.start(
            group: group, childOptions: { $0.childChannelOption(.allowRemoteHalfClosure, value: false) },
            childInitializer: { channel in
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 1 << 20,
                    shouldUpgrade: { channel, head in
                        var headers: [String: String] = [:]
                        for (name, value) in head.headers {
                            headers[name.lowercased()] = value
                        }
                        state.withLockedValue { $0.requests.append(Request(uri: head.uri, headers: headers)) }
                        if case .reject = behavior {
                            return channel.eventLoop.makeSucceededFuture(nil)
                        }
                        return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            if case .forward(let make) = behavior {
                                try channel.pipeline.syncOperations.addHandler(FrameStreamBridge())
                                try channel.pipeline.syncOperations.addHandler(make())
                            } else {
                                try channel.pipeline.syncOperations.addHandler(
                                    FrameHandler(behavior: behavior, state: state))
                            }
                        }
                    })
                return channel.eventLoop.makeCompletedFuture {
                    try prefix(channel)
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(
                        withServerUpgrade: (upgraders: [upgrader], completionHandler: { _ in }))
                    if case .reject(let status) = behavior {
                        try channel.pipeline.syncOperations.addHandler(RejectHandler(status: status))
                    }
                }
            })
        return WebSocketTestServer(server: server, state: state)
    }
}

/// 升级后的帧处理。
private final class FrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let behavior: WebSocketTestServer.Behavior
    private let state: NIOLockedValueBox<WebSocketTestServer.State>
    private var echoed = 0
    private var sentClose = false

    init(behavior: WebSocketTestServer.Behavior, state: NIOLockedValueBox<WebSocketTestServer.State>) {
        self.behavior = behavior
        self.state = state
    }

    func handlerAdded(context: ChannelHandlerContext) {
        switch behavior {
        case .pingThenEcho:
            let frame = WebSocketFrame(fin: true, opcode: .ping, data: context.channel.allocator.buffer(string: "hi"))
            context.writeAndFlush(wrapOutboundOut(frame), promise: nil)
        case .sendFrame(let size):
            var data = context.channel.allocator.buffer(capacity: size)
            data.writeRepeatingByte(0x5A, count: size)
            context.writeAndFlush(wrapOutboundOut(WebSocketFrame(fin: true, opcode: .binary, data: data)), promise: nil)
        default:
            break
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .text, .continuation:
            let payload = frame.unmaskedData
            state.withLockedValue { $0.largestClientFrame = max($0.largestClientFrame, payload.readableBytes) }
            guard !sentClose else { return }
            context.writeAndFlush(
                wrapOutboundOut(WebSocketFrame(fin: true, opcode: .binary, data: payload)), promise: nil)
            echoed += 1
            if case .closeAfterFirstEcho = behavior, echoed == 1 {
                sentClose = true
                var status = context.channel.allocator.buffer(capacity: 2)
                status.write(webSocketErrorCode: .normalClosure)
                context.writeAndFlush(
                    wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: status)), promise: nil)
            }
        case .pong:
            state.withLockedValue { $0.pongs += 1 }
        case .connectionClose:
            state.withLockedValue { $0.clientCloses += 1 }
            if !sentClose {
                sentClose = true
                context.writeAndFlush(
                    wrapOutboundOut(WebSocketFrame(fin: true, opcode: .connectionClose, data: frame.unmaskedData)),
                    promise: nil)
            }
            context.close(promise: nil)
        default:
            break
        }
    }
}

/// 服务端方向的帧 ↔ 字节流：数据帧的载荷向上交出，写入的字节作为二进制帧发出；`close` 帧关闭连接。
private final class FrameStreamBridge: ChannelDuplexHandler {
    typealias InboundIn = WebSocketFrame
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = WebSocketFrame

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .binary, .text, .continuation:
            context.fireChannelRead(wrapInboundOut(frame.unmaskedData))
        case .connectionClose:
            context.close(promise: nil)
        default:
            break
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let frame = WebSocketFrame(fin: true, opcode: .binary, data: unwrapOutboundIn(data))
        context.write(wrapOutboundOut(frame), promise: promise)
    }
}

/// 未升级时以固定状态码回复并关闭。
private final class RejectHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let status: Int

    init(status: Int) {
        self.status = status
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        headers.add(name: "Connection", value: "close")
        let head = HTTPResponseHead(
            version: .http1_1, status: HTTPResponseStatus(statusCode: status), headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in context.close(promise: nil) }
    }
}
