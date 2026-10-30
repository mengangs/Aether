import AetherEngine
import Foundation
@preconcurrency import NetworkExtension

/// 把平台无关的 `TunnelNetworkSettingsSpec` 转换为 `NEPacketTunnelNetworkSettings`（docs/06 §3）。
public enum NetworkSettingsBuilder {
    public static func makeSettings(from spec: TunnelNetworkSettingsSpec) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: spec.tunnelRemoteAddress)
        settings.mtu = NSNumber(value: spec.mtu)

        let ipv4 = NEIPv4Settings(addresses: spec.ipv4.addresses, subnetMasks: spec.ipv4.subnetMasks)
        ipv4.includedRoutes = spec.ipv4.includedRoutes.map(ipv4Route)
        ipv4.excludedRoutes = spec.ipv4.excludedRoutes.map(ipv4Route)
        settings.ipv4Settings = ipv4

        if let spec6 = spec.ipv6 {
            let ipv6 = NEIPv6Settings(
                addresses: spec6.addresses, networkPrefixLengths: spec6.prefixLengths.map { NSNumber(value: $0) })
            ipv6.includedRoutes = spec6.includedRoutes.map(ipv6Route)
            ipv6.excludedRoutes = spec6.excludedRoutes.map(ipv6Route)
            settings.ipv6Settings = ipv6
        }

        if let dns = spec.dns {
            let dnsSettings = NEDNSSettings(servers: dns.servers)
            dnsSettings.matchDomains = dns.matchDomains
            settings.dnsSettings = dnsSettings
        }

        if let proxy = spec.proxy {
            let proxySettings = NEProxySettings()
            let server = NEProxyServer(address: proxy.host, port: proxy.port)
            proxySettings.httpEnabled = true
            proxySettings.httpServer = server
            proxySettings.httpsEnabled = true
            proxySettings.httpsServer = server
            proxySettings.exceptionList = proxy.exceptionList
            proxySettings.excludeSimpleHostnames = proxy.excludeSimpleHostnames
            proxySettings.matchDomains = proxy.matchDomains
            settings.proxySettings = proxySettings
        }
        return settings
    }

    /// `0.0.0.0/0.0.0.0` 用系统的默认路由对象。
    static func ipv4Route(_ route: TunnelNetworkSettingsSpec.Route) -> NEIPv4Route {
        if route.destination == "0.0.0.0", route.mask == "0.0.0.0" {
            return NEIPv4Route.default()
        }
        return NEIPv4Route(destinationAddress: route.destination, subnetMask: route.mask)
    }

    /// `::/0` 用系统的默认路由对象；前缀长度无法解析时按 128 处理。
    static func ipv6Route(_ route: TunnelNetworkSettingsSpec.Route) -> NEIPv6Route {
        let prefix = Int(route.mask) ?? 128
        if route.destination == "::", prefix == 0 {
            return NEIPv6Route.default()
        }
        return NEIPv6Route(destinationAddress: route.destination, networkPrefixLength: NSNumber(value: prefix))
    }
}
