import AetherFoundation
import NIOCore

/// 连接器能力（docs/06 §8.1）。
public struct OutboundCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let tcp = OutboundCapabilities(rawValue: 1 << 0)
    public static let udp = OutboundCapabilities(rawValue: 1 << 1)
    /// 目标域名交给远端解析。
    public static let remoteResolve = OutboundCapabilities(rawValue: 1 << 2)
}

/// 解析服务器地址时的地址族策略（docs/04 §5.2 `ip-version`）。
public enum AddressFamilyPreference: String, Sendable, Hashable {
    case dual
    case v4Only = "v4-only"
    case v6Only = "v6-only"
    case preferV4 = "prefer-v4"
    case preferV6 = "prefer-v6"
}

/// 地址族。
public enum AddressFamily: Sendable, Hashable {
    case v4
    case v6
}

/// 解析服务器域名（docs/06 §8.1）：节点服务器地址只走 DIRECT DNS，绝不返回 Fake IP。
/// 引擎以 `DNSService.resolve` 实现；测试可注入固定表。
public protocol ServerAddressResolver: Sendable {
    /// 解析一种地址族；没有该族地址时返回空数组，解析失败以 `AetherErrorProtocol` 失败。
    func resolve(_ host: String, family: AddressFamily, on eventLoop: any EventLoop) -> EventLoopFuture<[IPAddress]>
}

/// 一次拨号的上下文。
public struct DialContext: Sendable {
    public var flowID: FlowID
    public var eventLoop: any EventLoop
    /// 握手（含 TLS 与代理协议）的截止时间，自开始连接算起 15 秒（docs/06 §6.1）。
    public var deadline: NIODeadline
    /// 解析代理节点服务器地址。
    public var serverResolver: any ServerAddressResolver
    public var logger: Logger

    public init(
        flowID: FlowID, eventLoop: any EventLoop, deadline: NIODeadline, serverResolver: any ServerAddressResolver,
        logger: Logger
    ) {
        self.flowID = flowID
        self.eventLoop = eventLoop
        self.deadline = deadline
        self.serverResolver = serverResolver
        self.logger = logger
    }
}

/// 出站连接器（docs/06 §8.1）：返回的 Channel 已完成全部握手，管线两端收发的都是应用层载荷（`ByteBuffer`）。
/// 返回时 `autoRead` 为**关闭**状态：在调用方装好转发 Handler 之前不会读出任何数据（握手之后服务器紧跟着发来的
/// 字节由管线中的回放 Handler 保存）；调用方装好 Handler 后打开 `autoRead` 并发出一次 `read()`（`FlowRelay.glue` 即如此）。
public protocol OutboundConnector: Sendable {
    var name: String { get }
    var capabilities: OutboundCapabilities { get }
    func connect(to destination: Destination, context: DialContext) -> EventLoopFuture<any Channel>
    func openUDP(context: DialContext) -> EventLoopFuture<any OutboundUDPAssociation>
}

extension OutboundConnector {
    public func openUDP(context: DialContext) -> EventLoopFuture<any OutboundUDPAssociation> {
        context.eventLoop.makeFailedFuture(NetworkError(.netPolicyNoUDP, "\(name) does not relay UDP"))
    }
}

/// 出站 UDP 关联（docs/06 §10）。绑定到创建它的 EventLoop：属性与方法只在该 EventLoop 上使用。
public protocol OutboundUDPAssociation: AnyObject, Sendable {
    /// 收到来自 `source` 的数据报。
    var onDatagram: ((ByteBuffer, Destination) -> Void)? { get set }
    /// 发送数据报；发送失败（目标无法解析、socket 错误）时静默丢弃并计数。
    func send(_ payload: ByteBuffer, to destination: Destination)
    /// 关闭（重复调用无副作用）。
    func close()
    /// 关闭后完成（控制连接断开等原因导致的关闭也会完成）。
    var closeFuture: EventLoopFuture<Void> { get }
}
