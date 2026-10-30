import AetherFoundation

/// 隧道网络设置的平台无关描述（docs/06 §3）。`AetherTunnelSupport` 把它转换为 `NEPacketTunnelNetworkSettings`。
///
/// M0 的「空隧道」只路由 Fake IP 段、不改 DNS、不设代理（14 M0-07）；M2-09 起由运行配置生成完整设置（`make(from:)`）。
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

    public struct IPv6: Sendable, Equatable {
        public var addresses: [String]
        public var prefixLengths: [Int]
        /// `Route.mask` 为前缀长度。
        public var includedRoutes: [Route]
        public var excludedRoutes: [Route]

        public init(addresses: [String], prefixLengths: [Int], includedRoutes: [Route], excludedRoutes: [Route]) {
            self.addresses = addresses
            self.prefixLengths = prefixLengths
            self.includedRoutes = includedRoutes
            self.excludedRoutes = excludedRoutes
        }
    }

    /// 系统 HTTP / HTTPS 代理（`system-proxy = true`）。
    public struct Proxy: Sendable, Equatable {
        public var host: String
        public var port: Int
        public var exceptionList: [String]
        public var excludeSimpleHostnames: Bool
        public var matchDomains: [String]

        public init(
            host: String, port: Int, exceptionList: [String], excludeSimpleHostnames: Bool, matchDomains: [String]
        ) {
            self.host = host
            self.port = port
            self.exceptionList = exceptionList
            self.excludeSimpleHostnames = excludeSimpleHostnames
            self.matchDomains = matchDomains
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
    /// nil 表示不接管 IPv6。
    public var ipv6: IPv6?
    /// nil 表示不修改系统 DNS。
    public var dns: DNS?
    /// nil 表示不设置系统代理。
    public var proxy: Proxy?

    public init(
        tunnelRemoteAddress: String, mtu: Int, ipv4: IPv4, ipv6: IPv6? = nil, dns: DNS?, proxy: Proxy? = nil
    ) {
        self.tunnelRemoteAddress = tunnelRemoteAddress
        self.mtu = mtu
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.dns = dns
        self.proxy = proxy
    }

    /// 隧道接口的 IPv4 / IPv6 地址（hev 的 `tunnel.ipv4` / `tunnel.ipv6` 与之一致）。
    public static let interfaceIPv4 = "198.18.0.1"
    public static let interfaceIPv6 = "fd00:ae7e::1"

    /// 由运行配置生成完整设置（docs/06 §3）：
    /// - IPv4 包含路由为 `tun-included-routes`（为空时默认路由），并始终包含 `fake-ip-range`；排除 `skip-proxy` 中的 CIDR、
    ///   `tun-excluded-routes`、组播与受限广播；
    /// - IPv6 始终接管默认路由（`ipv6 = false` 时 DNS 不返回 AAAA），排除 `skip-proxy` 与 `tun-excluded-routes` 中的
    ///   IPv6 CIDR、链路本地与组播；
    /// - DNS 为隧道 DNS 地址并接管全部域名；`system-proxy = true` 时系统 HTTP / HTTPS 代理指向内部 HTTP 代理入站。
    public static func make(from configuration: RuntimeConfiguration) -> TunnelNetworkSettingsSpec {
        let general = configuration.general
        let skipCIDRs = general.skipProxy.compactMap { CIDR($0) }
        func unique(_ cidrs: [CIDR]) -> [CIDR] {
            var seen = Set<CIDR>()
            return cidrs.filter { seen.insert($0).inserted }
        }
        func ipv4Route(_ cidr: CIDR) -> Route {
            Route(destination: cidr.network.description, mask: cidr.ipv4SubnetMask?.description ?? "255.255.255.255")
        }
        func ipv6Route(_ cidr: CIDR) -> Route {
            Route(destination: cidr.network.description, mask: String(cidr.prefixLength))
        }
        var included = general.tunIncludedRoutes.filter(\.network.isIPv4)
        if included.isEmpty {
            included = [CIDR(ipv4: IPv4Address(0), prefixLength: 0)]
        }
        included.append(general.fakeIPRange)
        let excluded =
            (skipCIDRs + general.tunExcludedRoutes).filter(\.network.isIPv4) + [
                CIDR(ipv4: IPv4Address(224, 0, 0, 0), prefixLength: 4),
                CIDR(ipv4: IPv4Address(255, 255, 255, 255), prefixLength: 32),
            ]
        let excludedIPv6 =
            (skipCIDRs + general.tunExcludedRoutes).filter { !$0.network.isIPv4 }
            + [
                CIDR("fe80::/10"), CIDR("ff00::/8"),
            ].compactMap { $0 }
        let proxy =
            general.systemProxy
            ? Proxy(
                host: "127.0.0.1", port: HTTPProxyInbound.defaultPort, exceptionList: general.skipProxy,
                excludeSimpleHostnames: general.excludeSimpleHostnames, matchDomains: [""]) : nil
        return TunnelNetworkSettingsSpec(
            tunnelRemoteAddress: "127.0.0.1", mtu: general.tunMTU,
            ipv4: IPv4(
                addresses: [interfaceIPv4], subnetMasks: ["255.255.255.255"],
                includedRoutes: unique(included).map(ipv4Route), excludedRoutes: unique(excluded).map(ipv4Route)),
            ipv6: IPv6(
                addresses: [interfaceIPv6], prefixLengths: [128], includedRoutes: [Route(destination: "::", mask: "0")],
                excludedRoutes: unique(excludedIPv6).map(ipv6Route)),
            dns: DNS(servers: [RuntimeConfiguration.tunnelDNSAddress.description], matchDomains: [""]),
            proxy: proxy)
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
