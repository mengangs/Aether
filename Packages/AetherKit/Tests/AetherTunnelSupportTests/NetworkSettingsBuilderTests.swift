import AetherEngine
import NetworkExtension
import Testing

@testable import AetherTunnelSupport

@Test func emptyTunnelSettingsRouteOnlyFakeIPRange() throws {
    let settings = NetworkSettingsBuilder.makeSettings(from: .emptyTunnel)
    #expect(settings.tunnelRemoteAddress == "127.0.0.1")
    #expect(settings.mtu?.intValue == 1500)
    let ipv4 = try #require(settings.ipv4Settings)
    #expect(ipv4.addresses == ["198.18.0.1"])
    #expect(ipv4.subnetMasks == ["255.255.255.255"])
    let routes = try #require(ipv4.includedRoutes)
    #expect(routes.count == 1)
    #expect(routes.first?.destinationAddress == "198.18.0.0")
    #expect(routes.first?.destinationSubnetMask == "255.254.0.0")
    #expect(settings.dnsSettings == nil)
    #expect(settings.ipv6Settings == nil)
    #expect(settings.proxySettings == nil)
}

@Test func fullSettingsMapIPv6DNSAndSystemProxy() throws {
    let spec = TunnelNetworkSettingsSpec(
        tunnelRemoteAddress: "127.0.0.1", mtu: 1400,
        ipv4: .init(
            addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.255"],
            includedRoutes: [
                .init(destination: "0.0.0.0", mask: "0.0.0.0"), .init(destination: "198.18.0.0", mask: "255.254.0.0"),
            ],
            excludedRoutes: [.init(destination: "192.168.0.0", mask: "255.255.0.0")]),
        ipv6: .init(
            addresses: ["fd00:ae7e::1"], prefixLengths: [128], includedRoutes: [.init(destination: "::", mask: "0")],
            excludedRoutes: [.init(destination: "fe80::", mask: "10")]),
        dns: .init(servers: ["198.18.0.2"], matchDomains: [""]),
        proxy: .init(
            host: "127.0.0.1", port: 6171, exceptionList: ["*.local"], excludeSimpleHostnames: true,
            matchDomains: [""]))
    let settings = NetworkSettingsBuilder.makeSettings(from: spec)
    #expect(settings.mtu?.intValue == 1400)
    let ipv4 = try #require(settings.ipv4Settings)
    #expect(ipv4.includedRoutes?.first?.destinationAddress == NEIPv4Route.default().destinationAddress)
    #expect(ipv4.includedRoutes?.last?.destinationSubnetMask == "255.254.0.0")
    #expect(ipv4.excludedRoutes?.first?.destinationAddress == "192.168.0.0")
    let ipv6 = try #require(settings.ipv6Settings)
    #expect(ipv6.addresses == ["fd00:ae7e::1"])
    #expect(ipv6.networkPrefixLengths.map(\.intValue) == [128])
    #expect(ipv6.includedRoutes?.first?.destinationNetworkPrefixLength.intValue == 0)
    #expect(ipv6.excludedRoutes?.first?.destinationAddress == "fe80::")
    #expect(ipv6.excludedRoutes?.first?.destinationNetworkPrefixLength.intValue == 10)
    #expect(settings.dnsSettings?.servers == ["198.18.0.2"])
    #expect(settings.dnsSettings?.matchDomains == [""])
    let proxy = try #require(settings.proxySettings)
    #expect(proxy.httpEnabled && proxy.httpsEnabled)
    #expect(proxy.httpServer?.address == "127.0.0.1" && proxy.httpServer?.port == 6171)
    #expect(proxy.httpsServer?.port == 6171)
    #expect(proxy.exceptionList == ["*.local"])
    #expect(proxy.excludeSimpleHostnames)
    #expect(proxy.matchDomains == [""])
}
