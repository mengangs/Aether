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
