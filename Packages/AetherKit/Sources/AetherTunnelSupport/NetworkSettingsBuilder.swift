import AetherEngine
@preconcurrency import NetworkExtension

/// 把平台无关的 `TunnelNetworkSettingsSpec` 转换为 `NEPacketTunnelNetworkSettings`（docs/06 §3）。
public enum NetworkSettingsBuilder {
    public static func makeSettings(from spec: TunnelNetworkSettingsSpec) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: spec.tunnelRemoteAddress)
        settings.mtu = NSNumber(value: spec.mtu)

        let ipv4 = NEIPv4Settings(addresses: spec.ipv4.addresses, subnetMasks: spec.ipv4.subnetMasks)
        ipv4.includedRoutes = spec.ipv4.includedRoutes.map {
            NEIPv4Route(destinationAddress: $0.destination, subnetMask: $0.mask)
        }
        ipv4.excludedRoutes = spec.ipv4.excludedRoutes.map {
            NEIPv4Route(destinationAddress: $0.destination, subnetMask: $0.mask)
        }
        settings.ipv4Settings = ipv4

        if let dns = spec.dns {
            let dnsSettings = NEDNSSettings(servers: dns.servers)
            dnsSettings.matchDomains = dns.matchDomains
            settings.dnsSettings = dnsSettings
        }
        return settings
    }
}
