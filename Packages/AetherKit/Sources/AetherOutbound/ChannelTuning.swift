import NIOCore
import NIOPosix

/// 数据面 Channel 的统一参数（docs/06 §13）。入站与出站的每个 TCP Channel 都使用这里的值。
public enum ChannelTuning {
    /// 写缓冲水位：低 32 KiB / 高 64 KiB。超过高水位后 Channel 变为不可写，
    /// 胶水 Handler 据此停止读取对端（背压），回到低水位后恢复。
    public static let writeBufferWaterMark = ChannelOptions.Types.WriteBufferWaterMark(
        low: 32 * 1024, high: 64 * 1024)

    /// 单次读取的缓冲上限 64 KiB（自适应，初始 16 KiB）。与写缓冲水位一起决定每个流在用户态的最大缓冲量：
    /// 对端不可写时本端停止读取，所以一个方向最多缓冲「高水位 + 一次读取」。
    public static func receiveAllocator() -> AdaptiveRecvByteBufferAllocator {
        AdaptiveRecvByteBufferAllocator(minimum: 1024, initial: 16 * 1024, maximum: 64 * 1024)
    }

    /// 每次可读事件只读一次（默认最多 4 次）：胶水 Handler 在两次读取之间检查对端可写性，
    /// 把一个方向的用户态缓冲限制在「高水位 + 一次读取」以内（≤ 128 KiB）。
    public static let maxMessagesPerRead: UInt = 1

    /// TCP 连接到服务器的超时（docs/06 §6.1）。
    public static let connectTimeout = TimeAmount.seconds(8)

    /// 出站 TCP 的 `ClientBootstrap` 默认参数：允许半关闭、`TCP_NODELAY`、写缓冲水位、读缓冲上限、连接超时。
    public static func configure(_ bootstrap: ClientBootstrap) -> ClientBootstrap {
        bootstrap
            .channelOption(.allowRemoteHalfClosure, value: true)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelOption(.writeBufferWaterMark, value: writeBufferWaterMark)
            .channelOption(.recvAllocator, value: receiveAllocator())
            .channelOption(.maxMessagesPerRead, value: maxMessagesPerRead)
            .connectTimeout(connectTimeout)
    }

    /// 入站监听的 `ServerBootstrap` 默认参数（子 Channel 与出站相同）。
    public static func configure(_ bootstrap: ServerBootstrap) -> ServerBootstrap {
        bootstrap
            .serverChannelOption(.backlog, value: 256)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelOption(.tcpOption(.tcp_nodelay), value: 1)
            .childChannelOption(.writeBufferWaterMark, value: writeBufferWaterMark)
            .childChannelOption(.recvAllocator, value: receiveAllocator())
            .childChannelOption(.maxMessagesPerRead, value: maxMessagesPerRead)
    }
}
