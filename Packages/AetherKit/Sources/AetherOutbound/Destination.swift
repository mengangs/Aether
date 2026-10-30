import AetherFoundation

/// 连接目标（docs/06 §8.1）：域名或 IP，加端口。代理节点优先使用域名（远端解析）。
public enum Destination: Sendable, Hashable, CustomStringConvertible {
    case domain(Hostname, port: UInt16)
    case ip(IPAddress, port: UInt16)

    public var port: UInt16 {
        switch self {
        case .domain(_, let port), .ip(_, let port): return port
        }
    }

    /// 域名目标的主机名。
    public var hostname: Hostname? {
        if case .domain(let host, _) = self { return host }
        return nil
    }

    /// IP 目标的地址。
    public var ipAddress: IPAddress? {
        if case .ip(let address, _) = self { return address }
        return nil
    }

    /// 主机部分的文本（域名或 IP，IPv6 不带方括号）。
    public var hostText: String {
        switch self {
        case .domain(let host, _): return host.value
        case .ip(let address, _): return address.description
        }
    }

    /// `host:port`，IPv6 带方括号（请求记录的 destination 字段）。
    public var description: String {
        switch self {
        case .domain(let host, let port): return "\(host.value):\(port)"
        case .ip(.v6(let v6), let port): return "[\(v6)]:\(port)"
        case .ip(.v4(let v4), let port): return "\(v4):\(port)"
        }
    }

    /// 由主机文本构造：IP 字面量为 `.ip`，否则按域名规范化；无效时为 nil。
    public init?(host: some StringProtocol, port: UInt16) {
        let text = String(host)
        let unbracketed =
            text.hasPrefix("[") && text.hasSuffix("]") ? String(text.dropFirst().dropLast()) : text
        if let address = IPAddress(unbracketed) {
            self = .ip(address, port: port)
        } else if let hostname = Hostname(unbracketed) {
            self = .domain(hostname, port: port)
        } else {
            return nil
        }
    }
}
