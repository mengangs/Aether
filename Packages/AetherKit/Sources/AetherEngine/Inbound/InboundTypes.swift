import AetherFoundation
import AetherOutbound
import AetherRules
import NIOCore

/// 入站交给路由的一个 TCP 流（docs/06 §5–§6）。
public struct InboundTCPRequest: Sendable {
    public var inbound: RouteContext.InboundKind
    public var destination: Destination
    /// 入站监听端口（`IN-PORT` 规则）。
    public var inboundPort: UInt16?
    /// 入站握手之后已经读出、尚未转发的字节（客户端在握手后立即发送的数据）。
    public var initialData: ByteBuffer?
    /// 入站是否已经向客户端确认连接成功（SOCKS5 立即回复；HTTP CONNECT 在出站建立后才回复）。
    public var replied: Bool

    public init(
        inbound: RouteContext.InboundKind, destination: Destination, inboundPort: UInt16? = nil,
        initialData: ByteBuffer? = nil, replied: Bool = true
    ) {
        self.inbound = inbound
        self.destination = destination
        self.inboundPort = inboundPort
        self.initialData = initialData
        self.replied = replied
    }
}

/// 接收入站新流的一方（M2-05 起由 `Router` 实现）。绑定到数据面 EventLoop，方法在该 EventLoop 上调用。
public protocol InboundAcceptor: AnyObject, Sendable {
    /// 接管一个 TCP 流。调用时入站 Channel 的 `autoRead` 已关闭，入站协议 Handler 已移除；
    /// 实现方负责后续的读取、转发与关闭。
    func acceptTCP(_ request: InboundTCPRequest, channel: any Channel)

    /// 接管一个 UDP 关联（SOCKS5 `UDP ASSOCIATE`）。实现方设置 `onDatagram` 并经 `send` 回包。
    func acceptUDP(_ association: SOCKS5UDPAssociation)
}

/// 常量时间比较（凭据校验）。
func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for index in lhs.indices {
        difference |= lhs[index] ^ rhs[index]
    }
    return difference == 0
}
