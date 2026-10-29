import NIOCore
import NIOPosix

/// 引擎的执行环境（docs/02 §7）：1 个 EventLoop 线程承载全部数据面；1 个线程池线程执行少量阻塞调用
/// （`getaddrinfo` 回退解析、NAT64 地址合成）。线程数可在测试与 `aether-cli` 中调整。
public final class EngineThreads: Sendable {
    public let group: MultiThreadedEventLoopGroup
    public let blockingPool: NIOThreadPool

    public init(eventLoopThreads: Int = 1, blockingThreads: Int = 1) {
        group = MultiThreadedEventLoopGroup(numberOfThreads: max(1, eventLoopThreads))
        blockingPool = NIOThreadPool(numberOfThreads: max(1, blockingThreads))
        blockingPool.start()
    }

    /// 数据面使用的 EventLoop（1 线程时恒为同一个）。
    public var eventLoop: any EventLoop { group.next() }

    /// 关闭线程池与 EventLoopGroup。调用前应先关闭全部 Channel。
    public func shutdown() async throws {
        try await blockingPool.shutdownGracefully()
        try await group.shutdownGracefully()
    }
}

/// 数据面各阶段超时（docs/06 §6.1）。
public struct EngineTimeouts: Sendable, Equatable {
    /// 嗅探等待首包。
    public var sniff: TimeAmount = .milliseconds(300)
    /// 路由用 DNS 解析。
    public var routingResolution: TimeAmount = .seconds(5)
    /// TCP 连接到服务器。
    public var connect: TimeAmount = .seconds(8)
    /// 代理握手（含 TLS），自连接开始计时。
    public var handshake: TimeAmount = .seconds(15)
    /// TCP 空闲（双向无数据）。
    public var tcpIdle: TimeAmount = .seconds(300)
    /// UDP 关联空闲。
    public var udpIdle: TimeAmount = .seconds(60)
    /// DNS 的 UDP 关联空闲。
    public var dnsUDPIdle: TimeAmount = .seconds(10)
    /// HTTP 管线 keep-alive 空闲。
    public var httpKeepAlive: TimeAmount = .seconds(60)
    /// 停止时半关闭后等待对端结束的时间，之后强制关闭（docs/06 §2.3）。
    public var stopGrace: TimeAmount = .seconds(1)

    public init() {}

    public static let `default` = EngineTimeouts()
}
