import AetherFoundation
import Testing

@testable import AetherDNS

@Suite("Fake IP pool")
struct FakeIPPoolTests {
    private func pool(_ cidr: String) -> FakeIPPool {
        FakeIPPool(range: CIDR(cidr)!)
    }

    @Test("Allocations are stable, unique and reversible")
    func allocation() {
        let pool = pool("198.18.0.0/15")
        let a = pool.address(for: "a.example.com")
        let b = pool.address(for: "b.example.com")
        #expect(a != b)
        #expect(pool.address(for: "a.example.com") == a)
        #expect(a == IPv4Address(198, 18, 0, 3))
        #expect(pool.domain(for: .v4(a)) == "a.example.com")
        #expect(pool.domain(for: .v4(IPv4Address(198, 18, 9, 9))) == nil)
        #expect(pool.domain(for: IPAddress("192.0.2.1")!) == nil)
        #expect(pool.contains(IPAddress("198.19.255.255")!))
        #expect(!pool.contains(IPAddress("198.20.0.0")!))
        #expect(pool.capacity == (1 << 17) - 4)
    }

    @Test("Reserved addresses are never handed out and the oldest mapping is recycled")
    func reservedAndRecycling() {
        // /29：8 个地址，保留 .0 .1 .2 .7，可分配 .3–.6。
        let pool = pool("192.0.2.0/29")
        #expect(pool.capacity == 4)
        let first = (0..<4).map { pool.address(for: "host\($0).example") }
        #expect(Set(first.map(\.description)) == ["192.0.2.3", "192.0.2.4", "192.0.2.5", "192.0.2.6"])
        #expect(!pool.didStartRecycling)
        // 使用 host0，使 host1 成为最久未用者。
        #expect(pool.domain(for: .v4(first[0])) == "host0.example")
        let recycled = pool.address(for: "new.example")
        #expect(pool.didStartRecycling)
        #expect(recycled == first[1])
        #expect(pool.domain(for: .v4(first[1])) == "new.example")
        #expect(pool.count == 4)
        for index in 0..<200 {
            let address = pool.address(for: "churn\(index).example")
            #expect(!["192.0.2.0", "192.0.2.1", "192.0.2.2", "192.0.2.7"].contains(address.description))
        }
    }

    @Test("Snapshots round-trip and keep recency order")
    func persistence() {
        let pool = pool("198.18.0.0/15")
        for index in 0..<10 { _ = pool.address(for: "d\(index).example") }
        _ = pool.address(for: "d0.example")
        let bytes = pool.serialize()
        let restored = FakeIPPool(range: CIDR("198.18.0.0/15")!)
        #expect(restored.load(bytes))
        #expect(restored.mappings().map(\.domain) == pool.mappings().map(\.domain))
        #expect(restored.mappings().map(\.address) == pool.mappings().map(\.address))
        // 恢复后继续分配不会与已载入的映射冲突。
        let fresh = restored.address(for: "fresh.example")
        #expect(!pool.mappings().map(\.address).contains(fresh))

        let limited = pool.serialize(limit: 3)
        let partial = FakeIPPool(range: CIDR("198.18.0.0/15")!)
        #expect(partial.load(limited))
        #expect(partial.count == 3)
        #expect(partial.mappings().first?.domain == "d0.example")
    }

    @Test("Corrupt or foreign snapshots are discarded")
    func corruptSnapshots() {
        let pool = pool("198.18.0.0/15")
        _ = pool.address(for: "keep.example")
        #expect(!pool.load([]))
        #expect(!pool.load(Array("NOPE".utf8) + [1, 0, 0, 0, 0]))
        var truncated = pool.serialize()
        truncated.removeLast()
        #expect(!pool.load(truncated))
        // 失败的载入不改变现有映射。
        #expect(pool.mappings().map(\.domain) == ["keep.example"])
        // 越界与保留偏移被逐条跳过。
        var bytes = FakeIPPool.magic + [FakeIPPool.formatVersion, 0, 0, 0, 2]
        bytes += [0, 0, 0, 1, 3] + Array("bad".utf8)
        bytes += [0, 0, 0, 9, 2] + Array("ok".utf8)
        #expect(pool.load(bytes))
        #expect(pool.mappings().map(\.domain) == ["ok"])
    }
}

@Suite("Host table and patterns")
struct HostTableTests {
    @Test("Glob patterns")
    func glob() {
        #expect(DomainPattern("*.example.com").matches("a.b.example.com"))
        #expect(!DomainPattern("*.example.com").matches("example.com"))
        #expect(DomainPattern("stun.*").matches("stun.l.example.net"))
        #expect(DomainPattern("api?.example.com").matches("api1.example.com"))
        #expect(!DomainPattern("api?.example.com").matches("api12.example.com"))
        #expect(DomainPattern("*").matches("anything"))
        #expect(DomainPattern("a*b*c").matches("axxbyyc"))
        #expect(!DomainPattern("a*b*c").matches("axxbyy"))
        #expect(DomainPattern("Example.COM").matches("example.com"))
    }

    @Test("Exact entries win over wildcards; wildcards keep configuration order")
    func priority() {
        let table = HostTable(entries: [
            HostEntry(pattern: "*.example.com", value: .addresses([IPAddress("192.0.2.1")!])),
            HostEntry(pattern: "*.cdn.example.com", value: .alias("edge.example.net")),
            HostEntry(pattern: "api.example.com", value: .upstream("192.0.2.53")),
        ])
        #expect(table.lookup("api.example.com") == .upstream("192.0.2.53"))
        #expect(table.lookup("img.cdn.example.com") == .addresses([IPAddress("192.0.2.1")!]))
        #expect(table.lookup("example.org") == nil)
    }

    @Test("Built-in real IP exceptions")
    func realIP() {
        let builtin = RealIPExceptions(patterns: nil)
        #expect(builtin.contains("printer.local"))
        #expect(builtin.contains("captive.apple.com"))
        #expect(builtin.contains("stun.l.example.net"))
        #expect(builtin.contains("pool.ntp.org"))
        #expect(!builtin.contains("www.example.com"))
        let custom = RealIPExceptions(patterns: ["*.corp.example"])
        #expect(custom.contains("git.corp.example"))
        #expect(!custom.contains("printer.local"))
    }
}
