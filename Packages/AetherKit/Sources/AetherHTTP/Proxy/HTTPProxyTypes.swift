import AetherFoundation
import AetherOutbound
import Foundation
import NIOCore
import NIOHTTP1

/// 一个明文 HTTP 代理请求的路由输入（docs/06 §5.2：按请求逐个路由，URL 与 User-Agent 对规则可见）。
public struct HTTPRouteRequest: Sendable {
    public var destination: Destination
    public var method: String
    /// 完整 URL（绝对形式）。
    public var url: String
    public var userAgent: String?
    public var inboundPort: UInt16?

    public init(destination: Destination, method: String, url: String, userAgent: String?, inboundPort: UInt16?) {
        self.destination = destination
        self.method = method
        self.url = url
        self.userAgent = userAgent
        self.inboundPort = inboundPort
    }
}

/// 拒绝类策略对明文 HTTP 请求的响应（docs/06 §8.3）。
public enum HTTPRejectResponse: Sendable, Equatable {
    /// `403`；`errorPage` 时附说明页（`show-error-page-for-reject`）。
    case forbidden(errorPage: Bool)
    /// `200` + 1×1 GIF。
    case tinyGIF
    /// 不发送任何数据，保持到客户端关闭或超时后关闭。
    case drop(TimeAmount)
}

/// 路由结果。
public enum HTTPRouteDecision: Sendable {
    case forward(HTTPForwardPlan)
    case reject(HTTPRejectResponse, observer: (any HTTPExchangeObserver)?)
    /// 无法转发（策略不可用、解析失败等）：回复 `502`。
    case fail(any AetherErrorProtocol, observer: (any HTTPExchangeObserver)?)
}

/// 转发计划：`reuseKey` 相同（同一策略、同一目标）时复用当前上游连接，否则调用 `dial` 建立新连接。
public struct HTTPForwardPlan: Sendable {
    public var reuseKey: String
    /// 在客户端 Channel 的 EventLoop 上调用，返回同一 EventLoop 上已建立的上游 Channel（收发原始字节）。
    public var dial: @Sendable () -> EventLoopFuture<any Channel>
    public var observer: (any HTTPExchangeObserver)?

    public init(
        reuseKey: String, dial: @escaping @Sendable () -> EventLoopFuture<any Channel>,
        observer: (any HTTPExchangeObserver)?
    ) {
        self.reuseKey = reuseKey
        self.dial = dial
        self.observer = observer
    }
}

/// 一次请求 / 响应交换的观察者（请求记录）。绑定到客户端 Channel 的 EventLoop，方法在该 EventLoop 上调用。
public protocol HTTPExchangeObserver: AnyObject, Sendable {
    /// 为本次交换新建了上游连接。
    func upstreamConnected(remoteAddress: String?)
    func responseStarted(status: Int)
    func transferred(up: Int, down: Int)
    /// 交换结束（成功时 `error` 为 nil），只调用一次。
    func finished(error: (any AetherErrorProtocol)?)
}

/// HTTP 代理入站的决策方（M2-05 起由 `Router` 实现）。
public protocol HTTPProxyDelegate: AnyObject, Sendable {
    /// `CONNECT`：交出 Channel（`autoRead` 已关闭，HTTP 编解码器已移除）。出站建立后调用
    /// `replier.established()` 回复 `200` 再开始转发；失败时调用 `replier.fail`（docs/06 §5.2）。
    func connect(
        _ destination: Destination, channel: any Channel, initialData: ByteBuffer?, replier: HTTPConnectReplier)

    /// 明文绝对形式请求：路由并给出转发计划。在客户端 Channel 的 EventLoop 上调用。
    func route(_ request: HTTPRouteRequest, channel: any Channel) -> EventLoopFuture<HTTPRouteDecision>
}

/// `CONNECT` 的回复。
public struct HTTPConnectReplier: Sendable {
    public let channel: any Channel

    public init(channel: any Channel) {
        self.channel = channel
    }

    /// 回复 `200 Connection Established`。
    public func established() -> EventLoopFuture<Void> {
        channel.writeAndFlush(ByteBuffer(string: "HTTP/1.1 200 Connection Established\r\n\r\n"))
    }

    /// 回复错误状态（如 `502`、拒绝策略的 `403`）并关闭连接。
    public func fail(status: HTTPResponseStatus, body: String = "") {
        let response =
            "HTTP/1.1 \(status.code) \(status.reasonPhrase)\r\nContent-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let channel = self.channel
        channel.writeAndFlush(ByteBuffer(string: response)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

/// 代理转发时的头部处理（RFC 9110 §7.6.1）。
public enum HTTPHopByHop {
    static let names: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "proxy-authorization", "proxy-authenticate", "te", "trailer",
        "upgrade",
    ]

    /// 去掉逐跳头与 `Connection` 中列出的头。`Transfer-Encoding` 保留，由 NIO 编码器按实际分帧方式整理。
    public static func strip(_ headers: inout HTTPHeaders) {
        let listed = headers["connection"].flatMap { $0.split(separator: ",") }.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        for name in names.union(listed) where name != "transfer-encoding" {
            headers.remove(name: name)
        }
    }
}

/// 绝对形式请求目标的解析结果。
struct AbsoluteTarget: Equatable {
    var host: String
    var port: UInt16
    /// 源站形式：路径 + 查询，至少为 `/`。
    var originForm: String
    /// `Host` 头的值。
    var authority: String

    /// 只接受 `http://`；`https://` 的绝对形式不会由正常客户端发出，按无效处理。
    init?(uri: String) {
        guard uri.count > 7, uri.prefix(7).lowercased() == "http://" else { return nil }
        let rest = uri.dropFirst(7)
        let authorityEnd = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
        var authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@") {
            authority = authority[authority.index(after: at)...]
        }
        guard !authority.isEmpty else { return nil }
        var path = String(rest[authorityEnd...])
        if let hash = path.firstIndex(of: "#") {
            path = String(path[..<hash])
        }
        if path.isEmpty || path.hasPrefix("?") {
            path = "/" + path
        }
        let host: Substring
        var port: UInt16 = 80
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            host = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let value = UInt16(after.dropFirst()), value > 0 else { return nil }
                port = value
            }
        } else if let colon = authority.lastIndex(of: ":") {
            host = authority[..<colon]
            guard let value = UInt16(authority[authority.index(after: colon)...]), value > 0 else { return nil }
            port = value
        } else {
            host = authority
        }
        guard !host.isEmpty else { return nil }
        self.host = String(host)
        self.port = port
        originForm = path
        self.authority = String(authority)
    }
}

/// `CONNECT host:port` 的目标。
enum ConnectTarget {
    static func parse(_ uri: String) -> Destination? {
        let host: Substring
        let portText: Substring
        if uri.hasPrefix("[") {
            guard let close = uri.firstIndex(of: "]"), uri[uri.index(after: close)...].hasPrefix(":") else {
                return nil
            }
            host = uri[uri.index(after: uri.startIndex)..<close]
            portText = uri[uri.index(close, offsetBy: 2)...]
        } else {
            guard let colon = uri.lastIndex(of: ":") else { return nil }
            host = uri[..<colon]
            portText = uri[uri.index(after: colon)...]
        }
        guard let port = UInt16(portText), port > 0 else { return nil }
        return Destination(host: host, port: port)
    }
}

/// 1×1 透明 GIF（`REJECT-TINYGIF`）。
enum TinyGIF {
    static let bytes: [UInt8] = [
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF,
        0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x01, 0x44, 0x00, 0x3B,
    ]
}
