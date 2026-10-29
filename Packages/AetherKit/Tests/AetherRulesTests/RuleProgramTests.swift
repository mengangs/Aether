import AetherFoundation
import AetherProfile
import AetherTestSupport
import Testing

@testable import AetherRules

struct MatchingSemanticsTests {
    @Test func suffixBoundary() {
        let program = compileRules("DOMAIN-SUFFIX,example.com,P\nFINAL,F")
        #expect(decide(program, context(host: "a.example.com")).policy == "P")
        #expect(decide(program, context(host: "example.com")).policy == "P")
        #expect(decide(program, context(host: "notexample.com")).policy == "F")
        #expect(decide(program, context(host: "example.com.cn")).policy == "F")
    }

    @Test func normalization() {
        let program = compileRules("DOMAIN,www.example.com,P\nDOMAIN-SUFFIX,例子.测试,U\nFINAL,F")
        #expect(decide(program, context(host: "WWW.Example.COM.")).policy == "P")
        #expect(decide(program, context(host: "a.xn--fsqu00a.xn--0zwm56d")).policy == "U")
        #expect(decide(program, context(host: "B.例子.测试")).policy == "U")
    }

    @Test func cidrBoundaries() {
        let program = compileRules("IP-CIDR,198.51.100.0/24,V4\nIP-CIDR6,2001:db8::/32,V6\nFINAL,F")
        #expect(decide(program, context(ip: "198.51.100.0")).policy == "V4")
        #expect(decide(program, context(ip: "198.51.100.255")).policy == "V4")
        #expect(decide(program, context(ip: "198.51.101.0")).policy == "F")
        #expect(decide(program, context(ip: "198.51.99.255")).policy == "F")
        #expect(decide(program, context(ip: "::ffff:198.51.100.7")).policy == "V4")
        #expect(decide(program, context(ip: "2001:db8:ffff:ffff:ffff:ffff:ffff:ffff")).policy == "V6")
        #expect(decide(program, context(ip: "2001:db9::")).policy == "F")
    }

    @Test func firstMatchWinsAcrossBlocks() {
        let program = compileRules(
            """
            DOMAIN-KEYWORD,shop,K
            DOMAIN,shop.example.com,D
            IP-CIDR,192.0.2.0/24,IP1
            DEST-PORT,443,PORT
            DOMAIN-SUFFIX,example.com,S
            IP-CIDR,192.0.2.0/25,IP2
            FINAL,F
            """)
        #expect(decide(program, context(host: "shop.example.com")).rule.index == 0)
        #expect(decide(program, context(host: "www.example.com", ip: "192.0.2.1")).policy == "IP1")
        #expect(decide(program, context(host: "www.example.com", port: 80)).policy == "S")
        #expect(decide(program, context(ip: "192.0.2.200", port: 80)).policy == "IP1")
    }

    @Test func noResolveSkipsResolution() {
        let program = compileRules("IP-CIDR,192.0.2.0/24,IP,no-resolve\nFINAL,F")
        #expect(
            program.evaluate(context(host: "a.example.com"))
                == .decided(
                    RuleMatch(
                        policy: "F",
                        rule: RuleReference(
                            index: 1, raw: "FINAL,F", source: SourceReference(file: "t.conf", line: 3, raw: "FINAL,F")),
                        usedResolution: false)))
    }

    @Test func resolutionResumesAndMatchesDirectIP() {
        let program = compileRules("DOMAIN,other.example.com,O\nIP-CIDR,192.0.2.0/24,IP\nGEOIP,US,G\nFINAL,F")
        let step = program.evaluate(context(host: "a.example.com"))
        guard case .needsResolution(let host, let cursor) = step else {
            Issue.record("expected needsResolution, got \(step)")
            return
        }
        #expect(host.value == "a.example.com" && cursor.index == 1 && cursor.afterResolution)
        let resolved = decide(program, context(host: "a.example.com")) { _ in
            [IPAddress("2001:db8::1")!, IPAddress("192.0.2.9")!]
        }
        #expect(resolved.policy == "IP" && resolved.usedResolution)
        let direct = decide(program, context(host: "a.example.com", ip: "192.0.2.9"))
        #expect(direct.policy == resolved.policy && !direct.usedResolution)
    }

    @Test func dnsFailedFallsToFinal() {
        let program = compileRules("IP-CIDR,192.0.2.0/24,IP\nDOMAIN,a.example.com,LATER\nFINAL,F,dns-failed")
        let match = decide(program, context(host: "a.example.com")) { _ in nil }
        #expect(match.policy == "F" && match.usedResolution)
        let withoutFlag = compileRules("IP-CIDR,192.0.2.0/24,IP\nDOMAIN,a.example.com,LATER\nFINAL,F")
        #expect(decide(withoutFlag, context(host: "a.example.com")) { _ in nil }.policy == "LATER")
    }

    @Test func logicalRules() {
        let program = compileRules(
            #"""
            AND,((OR,((DOMAIN,a.example.com),(URL-REGEX,"^https://b\.example\.com/(x|y),z"))),(NOT,((DEST-PORT,443)))),L1
            NOT,((IP-CIDR,192.0.2.0/24)),NOTIP
            FINAL,F
            """#)
        #expect(decide(program, context(host: "a.example.com", ip: "203.0.113.1", port: 80)).policy == "L1")
        #expect(
            decide(
                program, context(host: "b.example.com", ip: "203.0.113.1", port: 80, url: "https://b.example.com/y,z")
            ).policy == "L1")
        #expect(decide(program, context(host: "a.example.com", ip: "203.0.113.1", port: 443)).policy == "NOTIP")
        #expect(decide(program, context(host: "c.example.com", ip: "192.0.2.1")).policy == "F")
        // NOT 的子规则需要 IP：先解析再判定。
        #expect(decide(program, context(host: "c.example.com")) { _ in [IPAddress("192.0.2.5")!] }.policy == "F")
        #expect(decide(program, context(host: "c.example.com")) { _ in [IPAddress("198.51.100.5")!] }.policy == "NOTIP")
        // 只有 IP 字面量、没有可解析的主机名时，IP 子规则直接判定。
        #expect(decide(program, context(ip: "198.51.100.5")).policy == "NOTIP")
    }

    @Test func undecidableRulesNeverMatch() {
        let program = compileRules(
            "URL-REGEX,example,U\nUSER-AGENT,*,UA\nPROCESS-NAME,Telegram,PN\nIN-PORT,6171,IN\nSUBNET,SSID:Home,S\nNOT,((URL-REGEX,x)),N\nFINAL,F"
        )
        #expect(decide(program, context(host: "example.com")).policy == "F")
        #expect(decide(program, context(host: "example.com", userAgent: "curl/8")).policy == "UA")
        #expect(decide(program, context(host: "example.com", inboundPort: 6171)).policy == "IN")
        #expect(
            decide(program, context(host: "example.com", network: NetworkSnapshot(interfaceType: .wifi, ssid: "Home")))
                .policy == "S")
    }

    @Test func protocolPortAndHostnameType() {
        let program = compileRules(
            "PROTOCOL,UDP,UDP\nPROTOCOL,HTTP,HTTP\nDEST-PORT,8000-8080,PORTS\nHOSTNAME-TYPE,IPv6,V6\nHOSTNAME-TYPE,SIMPLE,SIMPLE\nHOSTNAME-TYPE,IPv4,V4\nFINAL,F"
        )
        #expect(decide(program, context(host: "x.example.com", transport: .udp)).policy == "UDP")
        #expect(decide(program, context(host: "x.example.com", app: .http)).policy == "HTTP")
        #expect(decide(program, context(host: "x.example.com", port: 8080)).policy == "PORTS")
        #expect(decide(program, context(ip: "2001:db8::1")).policy == "V6")
        #expect(decide(program, context(host: "router")).policy == "SIMPLE")
        #expect(decide(program, context(host: "192.0.2.1")).policy == "V4")
        #expect(decide(program, context(host: "x.example.com")).policy == "F")
    }

    @Test func geoIPAndASN() {
        let lookup = FakeLookup(countries: ["192.0.2.1": "cn"], asns: ["192.0.2.2": 64496])
        let program = compileRules(
            "GEOIP,CN,CN\nIP-ASN,64496,AS\nFINAL,F", resources: FakeResources(geoIP: lookup, ipASN: lookup))
        #expect(decide(program, context(ip: "192.0.2.1")).policy == "CN")
        #expect(decide(program, context(ip: "192.0.2.2")).policy == "AS")
        #expect(decide(program, context(host: "a.example.com")) { _ in [IPAddress("192.0.2.1")!] }.policy == "CN")
        // 没有数据库：不可判定，也不为它发起解析。
        let noDB = compileRules("GEOIP,CN,CN\nFINAL,F")
        #expect(noDB.evaluate(context(host: "a.example.com")).isDecided)
    }

    @Test func ruleAndDomainSets() {
        let set = CompiledRuleSet(
            parseRuleSpecs("DOMAIN-SUFFIX,ads.example.com,X\nIP-CIDR,203.0.113.0/24,X\nUSER-AGENT,Bad*,X").map {
                RuleSpec(condition: $0.condition, policy: nil, options: $0.options, raw: $0.raw, source: $0.source)
            })
        var domains = ReversedDomainTable.Builder()
        domains.add(domain: "stream.example.net", isSuffix: true, value: 0)
        let resources = FakeResources(
            ruleSets: ["https://r.example.com/ads.list": set],
            domainSets: ["https://r.example.com/s.txt": domains.build()])
        let program = compileRules(
            "RULE-SET,https://r.example.com/ads.list,REJECT\nDOMAIN-SET,https://r.example.com/s.txt,STREAM\nRULE-SET,https://r.example.com/missing.list,MISSING\nFINAL,F",
            resources: resources)
        #expect(decide(program, context(host: "x.ads.example.com")).policy == "REJECT")
        #expect(decide(program, context(host: "cdn.stream.example.net")).policy == "STREAM")
        #expect(decide(program, context(host: "a.example.com", userAgent: "BadBot")).policy == "REJECT")
        #expect(decide(program, context(host: "a.example.com")) { _ in [IPAddress("203.0.113.5")!] }.policy == "REJECT")
        #expect(decide(program, context(host: "a.example.com")) { _ in [IPAddress("198.51.100.5")!] }.policy == "F")
        let noResolve = compileRules(
            "RULE-SET,https://r.example.com/ads.list,REJECT,no-resolve\nFINAL,F", resources: resources)
        #expect(noResolve.evaluate(context(host: "a.example.com")).isDecided)
    }
}

extension RuleStep {
    var isDecided: Bool {
        if case .decided = self { return true }
        return false
    }
}

struct TraceAndCacheTests {
    @Test func traceListsEveryStep() {
        let program = compileRules(
            "DOMAIN-SUFFIX,google.com,Proxy\nGEOIP,CN,DIRECT\nIP-CIDR,192.0.2.0/24,LAN\nFINAL,Proxy")
        let trace = program.evaluateWithTrace(context(host: "www.example.com")) { _ in [IPAddress("192.0.2.14")!] }
        #expect(
            trace.entries.map(\.outcome) == [.noMatch, .undecidable("GeoIP database not loaded"), .needsIP, .match])
        #expect(trace.entries[2].note == "www.example.com = 192.0.2.14")
        #expect(trace.match.policy == "LAN" && trace.match.usedResolution)
        #expect(trace.resolution?.addresses == [IPAddress("192.0.2.14")!])
    }

    @Test func cacheStoresOnlyPureDecisions() {
        let program = compileRules("URL-REGEX,secret,U\nDOMAIN,a.example.com,A\nIP-CIDR,192.0.2.0/24,IP\nFINAL,F")
        let cache = RuleDecisionCache(capacity: 8)
        // 判定中遇到 URL-REGEX：不缓存。
        _ = program.evaluate(context(host: "a.example.com"), cache: cache)
        #expect(cache.count == 0)
        let pure = compileRules("DOMAIN,a.example.com,A\nIP-CIDR,192.0.2.0/24,IP\nFINAL,F")
        let pureCache = RuleDecisionCache()
        _ = pure.evaluate(context(host: "a.example.com"), cache: pureCache)
        _ = pure.evaluate(context(host: "a.example.com"), cache: pureCache)
        #expect(pureCache.count == 1 && pureCache.hits == 1)
        // 需要解析：不缓存。
        #expect(!pure.evaluate(context(host: "b.example.com"), cache: pureCache).isDecided)
        #expect(pureCache.count == 1)
        // 键包含端口与网络修订号。
        _ = pure.evaluate(context(host: "a.example.com", port: 80), cache: pureCache)
        _ = pure.evaluate(context(host: "a.example.com", network: NetworkSnapshot(revision: 2)), cache: pureCache)
        #expect(pureCache.count == 3)
    }

    @Test func implicitFinal() {
        let program = RuleProgram.compile([])
        #expect(decide(program, context(host: "a.example.com")).policy == "DIRECT")
    }
}

/// 块索引模式与逐条（追踪）模式结果一致（docs/05 §9 一致性属性测试，固定种子）。
struct ConsistencyPropertyTests {
    static let hosts = [
        "a.example.com", "b.a.example.com", "shop.example.net", "cdn1.example.org", "router", "x.example",
        "ads.tracker.example.com",
    ]
    static let ips = [
        "192.0.2.1", "192.0.2.200", "198.51.100.7", "203.0.113.9", "2001:db8::1", "2001:db8:1::5", "::ffff:192.0.2.9",
    ]

    static func randomRule(_ rng: inout SplitMix64, depth: Int = 0) -> String {
        func pick<T>(_ items: [T]) -> T { items[Int(rng.next() % UInt64(items.count))] }
        let choice = rng.next() % (depth > 1 ? 9 : 12)
        switch choice {
        case 0: return "DOMAIN,\(pick(hosts))"
        case 1: return "DOMAIN-SUFFIX,\(pick(["example.com", "a.example.com", "example.net", "org", "example"]))"
        case 2: return "DOMAIN-KEYWORD,\(pick(["shop", "cdn", "ads", "exam", "zzz"]))"
        case 3: return "DOMAIN-WILDCARD,\(pick(["*.example.com", "cdn?.example.org", "*", "r*r", "*.net"]))"
        case 4:
            return
                "IP-CIDR,\(pick(["192.0.2.0/24", "192.0.2.0/25", "198.51.100.0/24", "0.0.0.0/0", "203.0.113.9/32"]))\(pick(["", ",no-resolve"]))"
        case 5: return "IP-CIDR6,\(pick(["2001:db8::/32", "2001:db8:1::/48", "::/0"]))\(pick(["", ",no-resolve"]))"
        case 6: return "DEST-PORT,\(pick(["443", "80", "1-1024"]))"
        case 7: return "PROTOCOL,\(pick(["TCP", "UDP"]))"
        case 8: return "HOSTNAME-TYPE,\(pick(["IPv4", "IPv6", "DOMAIN", "SIMPLE"]))"
        case 9: return "AND,((\(randomRule(&rng, depth: depth + 1))),(\(randomRule(&rng, depth: depth + 1))))"
        case 10: return "OR,((\(randomRule(&rng, depth: depth + 1))),(\(randomRule(&rng, depth: depth + 1))))"
        default: return "NOT,((\(randomRule(&rng, depth: depth + 1))))"
        }
    }

    @Test func blockModeMatchesTraceMode() {
        var rng = SplitMix64(seed: 0x5EED)
        var checked = 0
        for _ in 0..<300 {
            let count = Int(rng.next() % 30) + 1
            var lines: [String] = []
            for index in 0..<count {
                let condition = Self.randomRule(&rng)
                lines.append(
                    condition.hasPrefix("AND") || condition.hasPrefix("OR") || condition.hasPrefix("NOT")
                        ? "\(condition),R\(index)" : "\(condition),R\(index)")
            }
            lines.append("FINAL,FINAL\(rng.next() % 2 == 0 ? ",dns-failed" : "")")
            let program = compileRules(lines.joined(separator: "\n"))
            for _ in 0..<20 {
                let useHost = rng.next() % 4 != 0
                let useIP = !useHost || rng.next() % 3 == 0
                let ctx = context(
                    host: useHost ? Self.hosts[Int(rng.next() % UInt64(Self.hosts.count))] : nil,
                    ip: useIP ? Self.ips[Int(rng.next() % UInt64(Self.ips.count))] : nil,
                    port: [443, 80, 8443][Int(rng.next() % 3)], transport: rng.next() % 2 == 0 ? .tcp : .udp)
                let answer: [IPAddress]? =
                    rng.next() % 4 == 0 ? nil : [IPAddress(Self.ips[Int(rng.next() % UInt64(Self.ips.count))])!]
                let fast = decide(program, ctx) { _ in answer }
                let trace = program.evaluateWithTrace(ctx) { _ in answer }
                if fast.rule.index != trace.match.rule.index || fast.usedResolution != trace.match.usedResolution {
                    Issue.record(
                        "mismatch: \(lines) ctx=\(ctx) answer=\(String(describing: answer)) fast=\(fast.rule.index) trace=\(trace.match.rule.index)"
                    )
                    return
                }
                checked += 1
            }
        }
        #expect(checked == 6000)
    }
}
