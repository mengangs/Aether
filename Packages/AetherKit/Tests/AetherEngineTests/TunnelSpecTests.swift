import AetherFoundation
import AetherProfile
import AetherRules
import Testing

@testable import AetherEngine

private func compile(_ text: String) -> RuntimeConfiguration {
    RuntimeConfiguration.compile(ProfileResolver.resolve(profileText: text, fileName: "tunnel.conf"))
}

@Suite("Tunnel network settings from the runtime configuration (06 §3)")
struct TunnelSpecTests {
    typealias Route = TunnelNetworkSettingsSpec.Route

    @Test("Defaults: default routes plus the Fake IP range, skip-proxy exclusions, IPv6, DNS and the system proxy")
    func defaults() {
        let spec = TunnelNetworkSettingsSpec.make(from: compile("[Rule]\nFINAL,DIRECT"))
        #expect(spec.tunnelRemoteAddress == "127.0.0.1")
        #expect(spec.mtu == 1500)
        #expect(spec.ipv4.addresses == ["198.18.0.1"] && spec.ipv4.subnetMasks == ["255.255.255.255"])
        #expect(
            spec.ipv4.includedRoutes == [
                Route(destination: "0.0.0.0", mask: "0.0.0.0"), Route(destination: "198.18.0.0", mask: "255.254.0.0"),
            ])
        #expect(
            spec.ipv4.excludedRoutes == [
                Route(destination: "127.0.0.0", mask: "255.0.0.0"), Route(destination: "10.0.0.0", mask: "255.0.0.0"),
                Route(destination: "172.16.0.0", mask: "255.240.0.0"),
                Route(destination: "192.168.0.0", mask: "255.255.0.0"),
                Route(destination: "100.64.0.0", mask: "255.192.0.0"),
                Route(destination: "169.254.0.0", mask: "255.255.0.0"),
                Route(destination: "224.0.0.0", mask: "240.0.0.0"),
                Route(destination: "255.255.255.255", mask: "255.255.255.255"),
            ])
        let ipv6 = spec.ipv6
        #expect(ipv6?.addresses == ["fd00:ae7e::1"] && ipv6?.prefixLengths == [128])
        #expect(ipv6?.includedRoutes == [Route(destination: "::", mask: "0")])
        #expect(
            ipv6?.excludedRoutes == [Route(destination: "fe80::", mask: "10"), Route(destination: "ff00::", mask: "8")])
        #expect(spec.dns == .init(servers: ["198.18.0.2"], matchDomains: [""]))
        #expect(
            spec.proxy
                == .init(
                    host: "127.0.0.1", port: 6171, exceptionList: GeneralSettings.defaultSkipProxy,
                    excludeSimpleHostnames: true, matchDomains: [""]))
    }

    @Test("Custom routes, MTU and skip-proxy; system-proxy = false leaves the proxy unset")
    func custom() {
        let spec = TunnelNetworkSettingsSpec.make(
            from: compile(
                """
                [General]
                tun-mtu = 1400
                tun-included-routes = 192.0.2.0/24, 198.18.0.0/15
                tun-excluded-routes = 203.0.113.0/24, 2001:db8::/32
                skip-proxy = 198.51.100.0/24, *.example.com, 2001:db8:1::/48
                system-proxy = false

                [Rule]
                FINAL,DIRECT
                """))
        #expect(spec.mtu == 1400)
        #expect(
            spec.ipv4.includedRoutes == [
                Route(destination: "192.0.2.0", mask: "255.255.255.0"),
                Route(destination: "198.18.0.0", mask: "255.254.0.0"),
            ])
        #expect(
            spec.ipv4.excludedRoutes.prefix(2) == [
                Route(destination: "198.51.100.0", mask: "255.255.255.0"),
                Route(destination: "203.0.113.0", mask: "255.255.255.0"),
            ])
        #expect(
            spec.ipv6?.excludedRoutes == [
                Route(destination: "2001:db8:1::", mask: "48"), Route(destination: "2001:db8::", mask: "32"),
                Route(destination: "fe80::", mask: "10"), Route(destination: "ff00::", mask: "8"),
            ])
        #expect(spec.proxy == nil)
    }
}

@Suite("hev configuration and utun framing (06 §4)")
struct HevSupportTests {
    @Test("The hev YAML carries the tunnel addresses, the internal SOCKS5 endpoint and the misc parameters")
    func hevYAML() {
        var configuration = HevConfiguration(
            socksPort: 52345, username: "ab'cd", password: "0123456789abcdef", mtu: 1400)
        configuration.logLevel = "warn"
        #expect(
            configuration.yaml == """
                tunnel:
                  mtu: 1400
                  ipv4: '198.18.0.1'
                  ipv6: 'fd00:ae7e::1'
                socks5:
                  address: '127.0.0.1'
                  port: 52345
                  udp: 'udp'
                  username: 'ab''cd'
                  password: '0123456789abcdef'
                misc:
                  task-stack-size: 65536
                  tcp-buffer-size: 16384
                  max-session-count: 1024
                  connect-timeout: 10000
                  tcp-read-write-timeout: 300000
                  udp-read-write-timeout: 60000
                  log-level: warn

                """)
        let credentials = SOCKS5Credentials(username: "u", password: "p")
        #expect(HevConfiguration(socksPort: 1, credentials: credentials).username == "u")
    }

    @Test("utun frames carry a 4-byte big-endian Darwin address family")
    func framing() {
        let ipv4: [UInt8] = [0x45, 0, 0, 20] + [UInt8](repeating: 0, count: 16)
        let ipv6: [UInt8] = [0x60, 0, 0, 0] + [UInt8](repeating: 0, count: 36)
        #expect(UTunFraming.wrap(ipv4)?.prefix(4) == [0, 0, 0, 2])
        #expect(UTunFraming.wrap(ipv6)?.prefix(4) == [0, 0, 0, 30])
        #expect(UTunFraming.wrap([0x10, 1, 2]) == nil)
        #expect(UTunFraming.wrap([]) == nil)
        let unwrapped = UTunFraming.unwrap(UTunFraming.wrap(ipv6)!)
        #expect(unwrapped?.packet == ipv6 && unwrapped?.family == UTunFraming.familyIPv6)
        #expect(UTunFraming.unwrap([0, 0, 0, 2]) == nil)
        #expect(UTunFraming.unwrap([0, 0, 0, 7, 0x45]) == nil)
    }

    @Test("Network environment changes: interface type, SSID and IP version availability")
    func environmentChanges() {
        let wifi = NetworkSnapshot(interfaceType: .wifi, ssid: "home", supportsIPv4: true, supportsIPv6: true)
        var same = wifi
        same.revision = 7
        same.isExpensive = true
        #expect(!same.differsInEnvironment(from: wifi))
        var other = wifi
        other.ssid = "office"
        #expect(other.differsInEnvironment(from: wifi))
        var noIPv6 = wifi
        noIPv6.supportsIPv6 = false
        #expect(noIPv6.differsInEnvironment(from: wifi))
        #expect(NetworkSnapshot(interfaceType: .cellular).differsInEnvironment(from: wifi))
    }
}
