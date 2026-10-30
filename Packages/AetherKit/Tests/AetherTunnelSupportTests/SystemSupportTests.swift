import AetherFoundation
import AetherRules
import Testing

@testable import AetherTunnelSupport

@Suite("Tunnel system support (06 §2.2, §4.1, §11)")
struct SystemSupportTests {
    @Test("The revision increases only when the network environment changes")
    func pathRevision() {
        let first = PathMonitor.next(NetworkSnapshot(interfaceType: .wifi, ssid: "home"), after: NetworkSnapshot())
        #expect(first.changed && first.snapshot.revision == 1)
        var expensive = first.snapshot
        expensive.isExpensive = true
        let same = PathMonitor.next(expensive, after: first.snapshot)
        #expect(!same.changed && same.snapshot.revision == 1 && same.snapshot.isExpensive)
        let cellular = PathMonitor.next(NetworkSnapshot(interfaceType: .cellular), after: same.snapshot)
        #expect(cellular.changed && cellular.snapshot.revision == 2)
    }

    @Test("RLIMIT_NOFILE is raised to at least min(hard limit, 8192)")
    func openFileLimit() throws {
        let limit = try #require(ResourceLimits.raiseOpenFileLimit())
        #expect(limit >= 256)
        // 再次调用不会降低。
        #expect(ResourceLimits.raiseOpenFileLimit(to: 64) == limit)
    }

    @Test("System DNS servers parse as addresses; a test process has no utun descriptor")
    func systemInterfaces() {
        let servers = SystemDNS.servers()
        #expect(servers.count <= 16)
        #expect(UTun.findDescriptor() == nil)
    }
}
