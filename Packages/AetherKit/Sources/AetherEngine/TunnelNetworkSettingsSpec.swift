/// 隧道网络设置的平台无关描述（docs/06 §3）。`AetherTunnelSupport` 把它转换为 `NEPacketTunnelNetworkSettings`。
///
/// M0 只有「空隧道」：只路由 Fake IP 段、不改 DNS、不设代理，开启后不影响正常上网（14 M0-07）。
/// M2-09 由运行配置生成完整设置。
public struct TunnelNetworkSettingsSpec: Sendable, Equatable {
    public struct Route: Sendable, Equatable {
        public var destination: String
        /// IPv4 为点分掩码，IPv6 为前缀长度。
        public var mask: String

        public init(destination: String, mask: String) {
            self.destination = destination
            self.mask = mask
        }
    }

    public struct IPv4: Sendable, Equatable {
        public var addresses: [String]
        public var subnetMasks: [String]
        public var includedRoutes: [Route]
        public var excludedRoutes: [Route]

        public init(addresses: [String], subnetMasks: [String], includedRoutes: [Route], excludedRoutes: [Route]) {
            self.addresses = addresses
            self.subnetMasks = subnetMasks
            self.includedRoutes = includedRoutes
            self.excludedRoutes = excludedRoutes
        }
    }

    public struct DNS: Sendable, Equatable {
        public var servers: [String]
        public var matchDomains: [String]

        public init(servers: [String], matchDomains: [String]) {
            self.servers = servers
            self.matchDomains = matchDomains
        }
    }

    public var tunnelRemoteAddress: String
    public var mtu: Int
    public var ipv4: IPv4
    /// nil 表示不修改系统 DNS。
    public var dns: DNS?

    public init(tunnelRemoteAddress: String, mtu: Int, ipv4: IPv4, dns: DNS?) {
        self.tunnelRemoteAddress = tunnelRemoteAddress
        self.mtu = mtu
        self.ipv4 = ipv4
        self.dns = dns
    }

    /// M0 的空隧道：接口地址 `198.18.0.1/32`，只包含 `198.18.0.0/15` 路由，不改 DNS。
    public static let emptyTunnel = TunnelNetworkSettingsSpec(
        tunnelRemoteAddress: "127.0.0.1",
        mtu: 1500,
        ipv4: IPv4(
            addresses: ["198.18.0.1"],
            subnetMasks: ["255.255.255.255"],
            includedRoutes: [Route(destination: "198.18.0.0", mask: "255.254.0.0")],
            excludedRoutes: []
        ),
        dns: nil
    )
}
