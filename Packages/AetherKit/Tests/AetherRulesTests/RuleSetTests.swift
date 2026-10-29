import AetherFoundation
import AetherProfile
import AetherTestSupport
import Foundation
import Testing

@testable import AetherRules

struct RuleSetParsingTests {
    @Test func parsesFixtureAndCountsSkippedLines() throws {
        let text = try Fixtures.string("rulesets/ads.list")
        let result = try RuleSetParser.parse(text, name: "ads.list").get()
        #expect(result.statistics.accepted == 9)
        #expect(result.statistics.unsupported == 1)
        #expect(result.statistics.disallowed == 2)
        #expect(result.statistics.invalid == 2)
        #expect(result.rules.allSatisfy { $0.policy == nil })
        #expect(result.rules[4].options.noResolve)
    }

    @Test func compiledFixtureMatches() throws {
        let rules = try RuleSetParser.parse(Fixtures.string("rulesets/ads.list"), name: "ads.list").get().rules
        let set = CompiledRuleSet(rules)
        #expect(set.ruleCount == 9 && set.dependsOnRequestDetails)
        #expect(set.match(context(host: "x.ads.example.com"), noResolve: false) == .match)
        #expect(set.match(context(host: "adserver1.example.com"), noResolve: false) == .match)
        #expect(set.match(context(host: "banner1.example.org"), noResolve: false) == .match)
        #expect(set.match(context(host: "a.example.net", port: 8443), noResolve: false) == .match)
        #expect(
            set.match(context(host: "a.example.org", url: "https://a.example.org/ads/x"), noResolve: false) == .match)
        #expect(set.match(context(ip: "203.0.113.4"), noResolve: false) == .match)
        // IP-CIDR6 不带 no-resolve：只有域名时需要解析；引用处带 no-resolve 时不需要。
        #expect(set.match(context(host: "clean.example.com"), noResolve: false) == .needsIP)
        #expect(set.match(context(host: "clean.example.com"), noResolve: true) == .noMatch)
        #expect(set.match(context(host: "clean.example.com", ip: "198.51.100.1"), noResolve: false) == .noMatch)
    }

    @Test func limitsAndEmptySets() {
        #expect(RuleSetParser.parse("# only comments\n\n", name: "e").failure == .noValidEntries)
        #expect(RuleSetParser.parse("PROCESS-NAME,x\nFINAL,DIRECT\n", name: "e").failure == .noValidEntries)
        #expect(
            RuleSetParser.parse(
                "DOMAIN,a.example.com\nDOMAIN,b.example.com\nDOMAIN,c.example.com", name: "e", maxEntries: 2
            ).failure == .tooManyEntries(count: 3))
        #expect(
            RuleSetParser.parse(String(repeating: "x", count: 100), name: "e", maxBytes: 64).failure
                == .tooLarge(bytes: 100))
        #expect(ResourceLoadError.tooLarge(bytes: 1).code == "RES-010")
        #expect(ResourceLoadError.noValidEntries.code == "RES-011")
    }
}

struct DomainSetTests {
    @Test func parsesFixture() throws {
        let result = try DomainSetLoader.load(Fixtures.string("rulesets/streaming.txt")).get()
        #expect(result.statistics.accepted == 4)
        #expect(result.statistics.invalid == 2)
        let table = result.table
        #expect(table.contains("stream.example.com"))
        #expect(table.contains("a.b.stream.example.com"))
        #expect(table.contains("video.example.net"))
        #expect(!table.contains("x.video.example.net"))
        #expect(table.contains("img.cdn.example.org"))
        #expect(table.contains("xn--fsqu00a.xn--0zwm56d"))
        #expect(!table.contains("example.com"))
    }

    @Test func limits() {
        #expect(DomainSetLoader.load("# nothing\n").failure == .noValidEntries)
        #expect(
            DomainSetLoader.load("a.example.com\nb.example.com\n", maxEntries: 1).failure == .tooManyEntries(count: 2))
        #expect(DomainSetLoader.load(String(repeating: "a", count: 10), maxBytes: 5).failure == .tooLarge(bytes: 10))
    }
}

struct BuiltinLANTests {
    @Test func lanMatchesLocalTargetsWithoutResolving() {
        let program = compileRules("RULE-SET,LAN,DIRECT\nFINAL,Proxy")
        #expect(decide(program, context(ip: "192.168.1.1")).policy == "DIRECT")
        #expect(decide(program, context(ip: "10.1.2.3")).policy == "DIRECT")
        #expect(decide(program, context(ip: "::1")).policy == "DIRECT")
        #expect(decide(program, context(ip: "fe80::1")).policy == "DIRECT")
        #expect(decide(program, context(host: "router")).policy == "DIRECT")
        #expect(decide(program, context(host: "printer.local")).policy == "DIRECT")
        #expect(decide(program, context(host: "nas.lan", ip: "192.168.1.20")).policy == "DIRECT")
        #expect(decide(program, context(ip: "198.51.100.1")).policy == "Proxy")
        // 只有域名的公网主机不为 LAN 发起解析。
        #expect(program.evaluate(context(host: "www.example.com")).isDecided)
        #expect(decide(program, context(host: "www.example.com")).policy == "Proxy")
    }
}

struct CompileCacheTests {
    static let hash = [UInt8](repeating: 0xAB, count: 32)

    @Test func ruleSetRoundTripsAndBehavesIdentically() throws {
        let rules = try RuleSetParser.parse(Fixtures.string("rulesets/ads.list"), name: "ads.list").get().rules
        let original = CompiledRuleSet(rules)
        let bytes = RuleCompileCache.encode(original, sourceSHA256: Self.hash)
        let decoded = try #require(RuleCompileCache.decodeRuleSet(bytes, sourceSHA256: Self.hash))
        #expect(decoded.ruleCount == original.ruleCount)
        #expect(decoded.dependsOnRequestDetails == original.dependsOnRequestDetails)
        let contexts = [
            context(host: "x.ads.example.com"), context(host: "adserver9.example.com"),
            context(host: "banner2.example.org"),
            context(host: "a.example.net", port: 8443), context(host: "clean.example.com"), context(ip: "203.0.113.9"),
            context(ip: "2001:db8:ad::1"), context(ip: "198.51.100.1"),
            context(host: "u.example.com", userAgent: "AdAgent/1"),
        ]
        for ctx in contexts {
            #expect(decoded.match(ctx, noResolve: false) == original.match(ctx, noResolve: false), "\(ctx)")
            #expect(decoded.match(ctx, noResolve: true) == original.match(ctx, noResolve: true), "\(ctx)")
        }
        // 再次编码得到相同字节（格式确定）。
        #expect(RuleCompileCache.encode(decoded, sourceSHA256: Self.hash).elementsEqual(bytes))
    }

    @Test func domainSetRoundTrips() throws {
        let table = try DomainSetLoader.load(Fixtures.string("rulesets/streaming.txt")).get().table
        let bytes = RuleCompileCache.encode(table, sourceSHA256: Self.hash)
        let decoded = try #require(RuleCompileCache.decodeDomainSet(bytes, sourceSHA256: Self.hash))
        for host in [
            "stream.example.com", "a.stream.example.com", "video.example.net", "x.video.example.net", "example.com",
        ] {
            #expect(decoded.contains(host) == table.contains(host))
        }
    }

    @Test func rejectsMismatchedOrCorruptCaches() throws {
        let table = try DomainSetLoader.load("a.example.com\n.b.example.com\n").get().table
        let bytes = RuleCompileCache.encode(table, sourceSHA256: Self.hash)
        #expect(RuleCompileCache.decodeDomainSet(bytes, sourceSHA256: [UInt8](repeating: 0, count: 32)) == nil)
        var wrongVersion = bytes
        wrongVersion[4] = 9
        #expect(RuleCompileCache.decodeDomainSet(wrongVersion, sourceSHA256: Self.hash) == nil)
        var wrongMagic = bytes
        wrongMagic[0] = UInt8(ascii: "X")
        #expect(RuleCompileCache.decodeDomainSet(wrongMagic, sourceSHA256: Self.hash) == nil)
        #expect(RuleCompileCache.decodeRuleSet(bytes, sourceSHA256: Self.hash) == nil)  // 域名集文件不是规则集
        #expect(RuleCompileCache.decodeDomainSet(Array(bytes.dropLast()), sourceSHA256: Self.hash) == nil)
        #expect(RuleCompileCache.decodeDomainSet(bytes + [0], sourceSHA256: Self.hash) == nil)
    }

    @Test func randomCorruptionNeverCrashes() throws {
        let rules = try RuleSetParser.parse(Fixtures.string("rulesets/ads.list"), name: "ads.list").get().rules
        let bytes = RuleCompileCache.encode(CompiledRuleSet(rules), sourceSHA256: Self.hash)
        var rng = SplitMix64(seed: 77)
        for _ in 0..<500 {
            var corrupted = bytes
            for _ in 0..<Int(rng.next() % 4) + 1 {
                let position = 38 + Int(rng.next() % UInt64(corrupted.count - 38))
                corrupted[position] = UInt8(truncatingIfNeeded: rng.next())
            }
            if rng.next() % 3 == 0 {
                corrupted = Array(corrupted.prefix(38 + Int(rng.next() % UInt64(corrupted.count - 38))))
            }
            if let decoded = RuleCompileCache.decodeRuleSet(corrupted, sourceSHA256: Self.hash) {
                _ = decoded.match(context(host: "x.ads.example.com"), noResolve: false)
            }
        }
    }
}

extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
