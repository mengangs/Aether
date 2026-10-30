/// hev-socks5-tunnel 的配置（docs/06 §4.2）：隧道启动时在内存中生成 YAML，交给 `hev_socks5_tunnel_main_from_str`。
///
/// 不使用 hev 的 `mapdns`：DNS 数据报经 SOCKS5 UDP 到达引擎的 DNS 服务。`misc` 中的参数为初值，待真机压测（V10）后定值。
public struct HevConfiguration: Sendable, Equatable {
    public var mtu = 1500
    public var ipv4 = TunnelNetworkSettingsSpec.interfaceIPv4
    public var ipv6 = TunnelNetworkSettingsSpec.interfaceIPv6
    /// 内部 SOCKS5 入站的端口。
    public var socksPort: Int
    /// 内部 SOCKS5 入站的凭据（每次启动随机生成的十六进制串）。
    public var username: String
    public var password: String
    public var taskStackSize = 65_536
    public var tcpBufferSize = 16_384
    public var maxSessionCount = 1024
    /// 毫秒。
    public var connectTimeout = 10_000
    public var tcpReadWriteTimeout = 300_000
    public var udpReadWriteTimeout = 60_000
    public var logLevel = "warn"

    public init(socksPort: Int, username: String, password: String, mtu: Int = 1500) {
        self.socksPort = socksPort
        self.username = username
        self.password = password
        self.mtu = mtu
    }

    public init(socksPort: Int, credentials: SOCKS5Credentials, mtu: Int = 1500) {
        self.init(
            socksPort: socksPort, username: String(decoding: credentials.username, as: UTF8.self),
            password: String(decoding: credentials.password, as: UTF8.self), mtu: mtu)
    }

    /// hev 的 YAML 配置。字符串值一律单引号包裹（单引号按 YAML 规则写成两个）。
    public var yaml: String {
        func quoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
        }
        return """
            tunnel:
              mtu: \(mtu)
              ipv4: \(quoted(ipv4))
              ipv6: \(quoted(ipv6))
            socks5:
              address: '127.0.0.1'
              port: \(socksPort)
              udp: 'udp'
              username: \(quoted(username))
              password: \(quoted(password))
            misc:
              task-stack-size: \(taskStackSize)
              tcp-buffer-size: \(tcpBufferSize)
              max-session-count: \(maxSessionCount)
              connect-timeout: \(connectTimeout)
              tcp-read-write-timeout: \(tcpReadWriteTimeout)
              udp-read-write-timeout: \(udpReadWriteTimeout)
              log-level: \(logLevel)

            """
    }
}
