import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// 测试用 TCP 服务：监听 `127.0.0.1` 的系统分配端口（测试不访问公网）。
public final class LoopbackTCPServer: Sendable {
    public let channel: any Channel

    private init(channel: any Channel) {
        self.channel = channel
    }

    /// 监听端口。
    public var port: Int {
        channel.localAddress?.port ?? 0
    }

    /// 启动服务，每个接受的连接调用 `childInitializer` 配置管线。
    public static func start(
        group: any EventLoopGroup,
        childOptions: @escaping @Sendable (ServerBootstrap) -> ServerBootstrap = { $0 },
        childInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Void>
    ) async throws -> LoopbackTCPServer {
        let bootstrap = childOptions(
            ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelOption(.allowRemoteHalfClosure, value: true)
                .childChannelInitializer(childInitializer)
        )
        let channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        return LoopbackTCPServer(channel: channel)
    }

    public func close() async throws {
        try await channel.close()
    }
}

/// 等待异步条件成立（只用于等待后台结果出现，判断依据是条件本身而不是经过的时长）。
public enum Poll {
    /// 条件成立返回 true；`timeout` 内一直不成立返回 false。
    @discardableResult
    public static func until(
        timeout: Duration = .seconds(10),
        interval: Duration = .milliseconds(10),
        _ condition: @Sendable () async throws -> Bool
    ) async rethrows -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() {
                return true
            }
            try? await Task.sleep(for: interval)
        }
        return try await condition()
    }
}

/// 收集 Channel 收到的全部字节与 EOF 的 Handler。
public final class CollectingHandler: ChannelInboundHandler, @unchecked Sendable {
    public typealias InboundIn = ByteBuffer

    private let state = NIOLockedValueBox<(bytes: [UInt8], eof: Bool, closed: Bool)>(([], false, false))

    public init() {}

    public var bytes: [UInt8] { state.withLockedValue { $0.bytes } }
    public var receivedEOF: Bool { state.withLockedValue { $0.eof } }
    public var isClosed: Bool { state.withLockedValue { $0.closed } }

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        state.withLockedValue { $0.bytes.append(contentsOf: buffer.readableBytesView) }
    }

    public func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            state.withLockedValue { $0.eof = true }
        }
        context.fireUserInboundEventTriggered(event)
    }

    public func channelInactive(context: ChannelHandlerContext) {
        state.withLockedValue {
            $0.eof = true
            $0.closed = true
        }
        context.fireChannelInactive()
    }
}
