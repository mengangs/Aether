import AetherFoundation
import AetherTestSupport
import Foundation
import Testing

@testable import AetherProfile

func fragment(_ text: String, module: Bool = false) -> ProfileFragment {
    let (document, lexical) = ProfileDocument.parse(text, fileName: module ? "test.amodule" : "test.conf")
    var result = FragmentParser.parse(document, isModule: module)
    result.diagnostics = lexical + result.diagnostics
    return result
}

func codes(_ diagnostics: [Diagnostic]) -> [String] {
    diagnostics.map(\.code.rawValue)
}

func general(_ body: String) -> (GeneralSettings, [String], [ExternalResourceRef]) {
    let parsed = fragment("[General]\n" + body)
    var sink = DiagnosticSink(file: "test.conf")
    var resources: [ExternalResourceRef] = []
    let settings = GeneralParser.parse(parsed.generalEntries, sink: &sink, resources: &resources)
    return (settings, codes(parsed.diagnostics + sink.diagnostics), resources)
}

struct GeneralParsingTests {
    @Test func defaults() {
        let (settings, diagnostics, _) = general("")
        #expect(diagnostics.isEmpty)
        #expect(settings.logLevel == "notice")
        #expect(settings.fakeIPRange.description == "198.18.0.0/15")
        #expect(settings.skipProxy.contains("*.local"))
        #expect(settings.tunMTU == 1500)
    }

    @Test func parsesEveryKey() throws {
        let (settings, diagnostics, resources) = general(
            """
            loglevel = verbose
            dns-server = system, 192.0.2.53, [2001:db8::53]:5353
            encrypted-dns-server = https://dns.example.net/dns-query, tls://dot.example.net
            encrypted-dns-skip-cert-verify = yes
            dns-mode = real-ip
            fake-ip-range = 198.18.0.0/16
            always-real-ip = *.lan, stun.*
            hijack-dns = *:53, 192.0.2.1:53
            skip-proxy = 192.168.0.0/16, *.local
            exclude-simple-hostnames = off
            system-proxy = false
            tun-included-routes = 0.0.0.0/0
            tun-excluded-routes = 203.0.113.0/24
            tun-mtu = 9000
            sniffing = 0
            block-quic = always
            udp-policy-not-supported-behaviour = direct
            internet-test-url = http://www.apple.com/library/test/success.html
            proxy-test-url = https://www.example.com/204
            test-timeout = 2.5
            geoip-maxmind-url = https://resources.example.com/country.mmdb
            ipasn-db-url = http://resources.example.com/asn.mmdb
            resource-update-interval = 3600
            resource-fetch-policy = Proxy
            show-error-page-for-reject = true
            wifi-access-http-port = 8080
            wifi-access-socks5-port = 8081
            """)
        #expect(diagnostics == ["CFG-090"])
        #expect(settings.logLevel == "debug")
        #expect(settings.dnsServers == ["system", "192.0.2.53", "[2001:db8::53]:5353"])
        #expect(settings.encryptedDNSServers.count == 2)
        #expect(settings.encryptedDNSSkipCertVerify)
        #expect(settings.dnsMode == .realIP)
        #expect(settings.fakeIPRange.prefixLength == 16)
        #expect(settings.alwaysRealIP == ["*.lan", "stun.*"])
        #expect(!settings.excludeSimpleHostnames && !settings.systemProxy && !settings.sniffing)
        #expect(settings.tunMTU == 9000)
        #expect(settings.blockQUIC == .always)
        #expect(settings.udpPolicyNotSupportedBehaviour == "DIRECT")
        #expect(settings.testTimeout == 2.5)
        #expect(settings.resourceFetchPolicy == "Proxy")
        #expect(resources.map(\.kind) == [.geoIPDatabase, .ipASNDatabase])
        #expect(settings.wifiAccessHTTPPort == 8080)
    }

    @Test(arguments: [
        ("loglevel = loud", "CFG-020"),
        ("dns-server = example.com", "CFG-020"),
        ("dns-mode = magic", "CFG-020"),
        ("fake-ip-range = 2001:db8::/64", "CFG-020"),
        ("fake-ip-range = 198.18.0.0/30", "CFG-020"),
        ("hijack-dns = everything", "CFG-020"),
        ("ipv6 = maybe", "CFG-020"),
        ("tun-mtu = 100", "CFG-020"),
        ("tun-excluded-routes = 10.0.0.0/33", "CFG-032"),
        ("block-quic = sometimes", "CFG-020"),
        ("udp-policy-not-supported-behaviour = proxy", "CFG-020"),
        ("test-timeout = -1", "CFG-020"),
        ("proxy-test-url = ftp://example.com/", "CFG-020"),
        ("geoip-db-url = ftp://example.com/db", "CFG-091"),
        ("http-api = nokey", "CFG-020"),
        ("wifi-access-http-port = 70000", "CFG-020"),
        ("replica = true", "CFG-003"),
        ("encrypted-dns-server = quic://dns.example.net", "CFG-099"),
        ("ipv6 = true", "CFG-099"),
    ])
    func rejectsOrNotesInvalidValues(_ line: String, _ code: String) {
        let (_, diagnostics, _) = general(line)
        #expect(diagnostics.contains(code), "\(line) → \(diagnostics)")
    }

    @Test func duplicateKeyWarnsAndLaterWins() {
        let (settings, diagnostics, _) = general("loglevel = info\nloglevel = error\n")
        #expect(diagnostics == ["CFG-005"])
        #expect(settings.logLevel == "error")
    }
}

struct ProxyParsingTests {
    private func proxy(_ line: String) -> (ProxySpec?, [String]) {
        let parsed = fragment("[Proxy]\n" + line)
        return (parsed.proxies.first, codes(parsed.diagnostics))
    }

    @Test func http() throws {
        let (spec, diagnostics) = proxy("Office = https, proxy.example.com, 443, alice, p@ss, sni=proxy.example.com")
        #expect(diagnostics.isEmpty)
        let parsed = try #require(spec)
        #expect(parsed.server == "proxy.example.com" && parsed.port == 443)
        #expect(parsed.proxyProtocol == .http(username: "alice", password: "p@ss", alwaysUseConnect: false))
        #expect(parsed.tls?.sni == .custom("proxy.example.com"))
        let (plain, _) = proxy("Plain = http, 192.0.2.1, 8080, username=bob, password=x, always-use-connect=true")
        #expect(plain?.proxyProtocol == .http(username: "bob", password: "x", alwaysUseConnect: true))
        #expect(plain?.tls == nil)
    }

    @Test func socks5() {
        let (spec, diagnostics) = proxy(
            "S = socks5-tls, 198.51.100.10, 1080, username=bob, password=pw, udp-relay=true, skip-cert-verify=true")
        #expect(diagnostics.isEmpty)
        #expect(spec?.proxyProtocol == .socks5(username: "bob", password: "pw"))
        #expect(spec?.udpRelay == true)
        #expect(spec?.tls?.skipCertVerify == true)
    }

    @Test func shadowsocks() {
        let (aead, d1) = proxy("HK = ss, hk.example.net, 8388, encrypt-method=aes-128-gcm, password=pw, udp-relay=true")
        #expect(d1.isEmpty)
        #expect(aead?.proxyProtocol == .shadowsocks(method: .aes128GCM, password: "pw", obfs: nil))
        let (obfs, d2) = proxy(
            "SG = ss, sg.example.net, 443, encrypt-method=chacha20-ietf-poly1305, password=pw, obfs=http, obfs-host=cdn.example.com"
        )
        #expect(d2.isEmpty)
        #expect(
            obfs?.proxyProtocol
                == .shadowsocks(
                    method: .chacha20IETFPoly1305, password: "pw",
                    obfs: SimpleObfs(mode: .http, host: "cdn.example.com", uri: nil)))
        let (ss2022, _) = proxy(
            "HK2 = ss, hk2.example.net, 8389, encrypt-method=2022-blake3-aes-128-gcm, password=AAAAAAAAAAAAAAAAAAAAAA=="
        )
        #expect(ss2022?.isUsable == true)
    }

    @Test func trojanVMessVLESS() throws {
        let (trojan, d1) = proxy(
            #"US = trojan, us.example.net, 443, password=pw, ws=true, ws-path=/t, ws-headers="Host:cdn.example.net|X-A:b, c""#
        )
        #expect(d1.isEmpty)
        #expect(trojan?.proxyProtocol == .trojan(password: "pw"))
        #expect(trojan?.webSocket?.path == "/t")
        #expect(
            trojan?.webSocket?.headers == [
                HTTPHeaderField(name: "Host", value: "cdn.example.net"), HTTPHeaderField(name: "X-A", value: "b, c"),
            ])
        #expect(trojan?.tls != nil)
        let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
        let (vmess, d2) = proxy(
            "JP = vmess, jp.example.net, 443, username=\(uuid), tls=true, ws=true, sni=jp.example.net")
        #expect(d2.isEmpty)
        #expect(vmess?.proxyProtocol == .vmess(uuid: uuid, cipher: .auto))
        #expect(vmess?.tls?.sni == .custom("jp.example.net"))
        let (vless, d3) = proxy("V = vless, v.example.net, 443, username=\(uuid.uppercased()), tls=true")
        #expect(d3.isEmpty)
        #expect(vless?.proxyProtocol == .vless(uuid: uuid))
        let (vmessNoTLS, _) = proxy("N = vmess, n.example.net, 80, username=\(uuid)")
        #expect(vmessNoTLS?.tls == nil)
    }

    @Test func aliasesAndFingerprint() throws {
        let (alias, d1) = proxy("国内直连 = direct")
        #expect(d1.isEmpty)
        #expect(alias?.proxyProtocol == .alias(.direct))
        let fp = String(repeating: "ab:", count: 31) + "ab"
        let (pinned, d2) = proxy(
            "P = https, a.example.com, 443, server-cert-fingerprint-sha256=\(fp), alpn=\"h2,http/1.1\"")
        #expect(d2.isEmpty)
        #expect(pinned?.tls?.certificateFingerprintSHA256?.count == 32)
        #expect(pinned?.tls?.alpn == ["h2", "http/1.1"])
    }

    @Test(arguments: [
        ("H = hysteria2, h.example.net, 443, password=x", "CFG-022", false),
        ("S = snell, s.example.net, 443, psk=x", "CFG-022", false),
        ("U = madeup, u.example.net, 443", "CFG-022", false),
        ("R = ss, r.example.net, 443, encrypt-method=rc4-md5, password=x", "CFG-023", false),
        (
            "O = vmess, o.example.net, 443, username=b831381d-6324-4d53-ad4f-8cda48b30811, vmess-aead=false", "CFG-023",
            false
        ),
        ("A = vmess, a.example.net, 443, username=b831381d-6324-4d53-ad4f-8cda48b30811, alterId=64", "CFG-023", false),
        (
            "X = vless, x.example.net, 443, username=b831381d-6324-4d53-ad4f-8cda48b30811, flow=xtls-rprx-vision",
            "CFG-023", false
        ),
        ("T = https, t.example.net, 443, tfo=true", "CFG-024", true),
        ("K = https, k.example.net, 443, unknown-thing=1", "CFG-003", true),
    ])
    func unavailableOrNoted(_ line: String, _ code: String, _ usable: Bool) throws {
        let (spec, diagnostics) = proxy(line)
        #expect(diagnostics.contains(code))
        #expect(try #require(spec).isUsable == usable)
    }

    @Test(arguments: [
        ("M = ss, m.example.net, 443, password=x", "CFG-021"),
        ("M = trojan, m.example.net, 443", "CFG-021"),
        ("M = vmess, m.example.net, 443", "CFG-021"),
        ("M = https, m.example.net", "CFG-021"),
        ("M = https, m.example.net, 99999", "CFG-020"),
        ("M = https, bad host, 443", "CFG-020"),
        ("M = vmess, m.example.net, 443, username=not-a-uuid", "CFG-020"),
        ("M = ss, m.example.net, 443, encrypt-method=rot13, password=x", "CFG-020"),
        ("M = ss, m.example.net, 443, encrypt-method=aes-128-gcm, password=x, obfs=quic", "CFG-020"),
        (#"M = https, "m.example.net, 443"#, "CFG-004"),
    ])
    func rejectsInvalid(_ line: String, _ code: String) {
        let (spec, diagnostics) = proxy(line)
        #expect(spec == nil)
        #expect(diagnostics.contains(code), "\(diagnostics)")
    }
}

struct GroupParsingTests {
    private func group(_ line: String) -> (PolicyGroupSpec?, [String]) {
        let parsed = fragment("[Proxy Group]\n" + line)
        return (parsed.groups.first, codes(parsed.diagnostics))
    }

    @Test func parsesEachType() throws {
        let (select, d1) = group("Proxy = select, Auto, HK-01, DIRECT")
        #expect(d1.isEmpty)
        #expect(select?.type == .select && select?.members == ["Auto", "HK-01", "DIRECT"])
        let (auto, d2) = group(
            "Auto = url-test, A, B, interval=300, tolerance=80, timeout=3, url=http://www.example.com/204, evaluate-before-use=true"
        )
        #expect(d2.isEmpty)
        #expect(auto?.interval == 300 && auto?.tolerance == 80 && auto?.timeout == 3 && auto?.evaluateBeforeUse == true)
        let (fallback, _) = group("F = fallback, A, B")
        #expect(fallback?.type == .fallback)
        let (balance, d3) = group("L = load-balance, A, B, persistent=true")
        #expect(d3.isEmpty && balance?.persistent == true)
        let (sub, d4) = group(
            #"Sub = select, policy-path=https://sub.example.com/x?token=t, policy-regex-filter=(HK|JP), update-interval=43200, include-all-proxies=true, include-other-group="A, B", hidden=true"#
        )
        #expect(d4.isEmpty)
        let parsed = try #require(sub)
        #expect(parsed.members.isEmpty && parsed.hasMemberSource)
        #expect(parsed.includeOtherGroups == ["A", "B"] && parsed.hidden && parsed.includeAllProxies)
        #expect(parsed.updateInterval == 43200)
    }

    @Test(arguments: [
        ("G = random, A", "CFG-020"),
        ("G = select, A, policy-regex-filter=[unclosed", "CFG-033"),
        ("G = select, A, policy-regex-filter=(unclosed", "CFG-004"),
        ("G = select, A, tolerance=10", "CFG-003"),
        ("G = url-test, A, interval=soon", "CFG-020"),
        ("G = select, policy-path=http://sub.example.com/x", "CFG-090"),
        ("G = select, A, colour=blue", "CFG-003"),
        ("G = subnet, A", "CFG-099"),
    ])
    func diagnostics(_ line: String, _ code: String) {
        let (_, diagnostics) = group(line)
        #expect(diagnostics.contains(code), "\(line) → \(diagnostics)")
    }
}

struct RuleParsingTests {
    private func rule(_ line: String) -> (RuleSpec?, [String]) {
        let parsed = fragment("[Rule]\n" + line)
        return (parsed.rules.first, codes(parsed.diagnostics))
    }

    @Test(arguments: [
        ("DOMAIN,WWW.Example.COM.,Proxy", RuleCondition.domain(Hostname("www.example.com")!)),
        ("DOMAIN-SUFFIX,例子.测试,Proxy", .domainSuffix(Hostname("xn--fsqu00a.xn--0zwm56d")!)),
        ("DOMAIN-KEYWORD,Tracker,REJECT", .domainKeyword("tracker")),
        ("DOMAIN-WILDCARD,*.CDN?.example.net,P", .domainWildcard("*.cdn?.example.net")),
        ("RULE-SET,lan,DIRECT", .ruleSet("LAN")),
        ("RULE-SET,https://rules.example.com/a.list,REJECT", .ruleSet("https://rules.example.com/a.list")),
        ("RULE-SET,local/ads.list,REJECT", .ruleSet("local/ads.list")),
        ("DOMAIN-SET,https://rules.example.com/s.txt,P", .domainSet("https://rules.example.com/s.txt")),
        ("IP-CIDR,192.0.2.7/24,DIRECT", .ipCIDR(CIDR("192.0.2.0/24")!)),
        ("IP-CIDR6,2001:db8::/32,DIRECT", .ipCIDR6(CIDR("2001:db8::/32")!)),
        ("GEOIP,cn,DIRECT", .geoIP("CN")),
        ("IP-ASN,AS64496,P", .ipASN(64496)),
        ("IP-ASN,64496,P", .ipASN(64496)),
        ("DEST-PORT,22,DIRECT", .destPort(22...22)),
        ("DEST-PORT,8000-8080,DIRECT", .destPort(8000...8080)),
        ("IN-PORT,6171,DIRECT", .inPort(6171...6171)),
        ("PROTOCOL,quic,REJECT", .protocol(.quic)),
        ("HOSTNAME-TYPE,simple,DIRECT", .hostnameType(.simple)),
        ("SUBNET,SSID:Home Wi-Fi,DIRECT", .subnet(.ssid("Home Wi-Fi"))),
        ("SUBNET,TYPE:cellular,P", .subnet(.interfaceType(.cellular))),
        ("USER-AGENT,ExampleApp*,P", .userAgent("ExampleApp*")),
        (
            #"URL-REGEX,"^https?://ads\.example\.com/(banner|popup)",REJECT"#,
            .urlRegex(#"^https?://ads\.example\.com/(banner|popup)"#)
        ),
        ("PROCESS-NAME,Telegram,P", .unsupported(type: "PROCESS-NAME", value: "Telegram")),
    ])
    func parsesConditions(_ line: String, _ expected: RuleCondition) throws {
        let (spec, diagnostics) = rule(line)
        let parsed = try #require(spec)
        #expect(parsed.condition == expected)
        #expect(diagnostics.allSatisfy { $0 == "CFG-031" })
    }

    @Test func logicalRules() throws {
        let (spec, diagnostics) = rule(
            #"AND,((OR,((DOMAIN,a.example.com),(URL-REGEX,"^https://a\.com/(x|y)"))),(NOT,((DEST-PORT,443))),(IP-CIDR,192.0.2.0/24,no-resolve)),DIRECT"#
        )
        #expect(diagnostics.isEmpty)
        guard case .and(let children) = try #require(spec).condition else {
            Issue.record("expected AND")
            return
        }
        #expect(children.count == 3)
        guard case .or(let inner) = children[0].condition else {
            Issue.record("expected OR")
            return
        }
        #expect(inner[1].condition == .urlRegex(#"^https://a\.com/(x|y)"#))
        #expect(
            children[1].condition
                == .not(
                    RuleSpec(
                        condition: .destPort(443...443), policy: nil, raw: "DEST-PORT,443", source: children[1].source))
        )
        #expect(children[2].options.noResolve)
        #expect(children.allSatisfy { $0.policy == nil })
        #expect(try #require(spec).condition.requiresIP)
    }

    @Test func optionsAndFinal() throws {
        let (ruleSet, d1) = rule("RULE-SET,https://rules.example.com/a.list,REJECT,update-interval=600,no-resolve")
        #expect(d1.isEmpty)
        #expect(ruleSet?.options == RuleOptions(noResolve: true, updateInterval: 600))
        let (final, d2) = rule("FINAL,Proxy,dns-failed")
        #expect(d2.isEmpty)
        #expect(final?.condition == .final && final?.options.dnsFailed == true && final?.policy == "Proxy")
        let (match, d3) = rule("MATCH,DIRECT")
        #expect(match?.condition == .final && d3 == ["CFG-099"])
        let (extended, d4) = rule("DOMAIN-SUFFIX,example.com,P,extended-matching")
        #expect(extended != nil && d4 == ["CFG-099"])
    }

    @Test func collectsRuleSetResources() {
        let parsed = fragment(
            "[Rule]\nRULE-SET,https://r.example.com/a.list,P,update-interval=60\nAND,((DOMAIN-SET,https://r.example.com/b.txt),(DEST-PORT,443)),P\nRULE-SET,LAN,DIRECT\n"
        )
        #expect(parsed.resources.map(\.url) == ["https://r.example.com/a.list", "https://r.example.com/b.txt"])
        #expect(parsed.resources.first?.updateInterval == 60)
    }

    @Test(arguments: [
        ("WHATEVER,x,P", "CFG-030"),
        ("IP-CIDR,2001:db8::/32,P", "CFG-032"),
        ("IP-CIDR6,192.0.2.0/24,P", "CFG-032"),
        ("IP-CIDR,300.0.0.0/8,P", "CFG-032"),
        ("URL-REGEX,(unclosed,P", "CFG-004"),
        (#"URL-REGEX,"(unclosed",P"#, "CFG-033"),
        ("DEST-PORT,0,P", "CFG-034"),
        ("DEST-PORT,90-80,P", "CFG-034"),
        ("DOMAIN-SUFFIX,example.com,P,no-resolve", "CFG-037"),
        ("RULE-SET,https://r.example.com/a,P,warp-speed", "CFG-037"),
        ("DOMAIN,example.com", "CFG-021"),
        ("FINAL", "CFG-021"),
        ("NOT,((DOMAIN,a.example.com),(DOMAIN,b.example.com)),P", "CFG-004"),
        ("AND,(DOMAIN,a.example.com),P", "CFG-004"),
        ("GEOIP,CHN,P", "CFG-020"),
        ("RULE-SET,ftp://r.example.com/a,P", "CFG-091"),
        ("RULE-SET,http://r.example.com/a,P", "CFG-090"),
        ("SCRIPT,my-rule,P", "CFG-031"),
        ("SUBNET,PLANET:mars,P", "CFG-020"),
    ])
    func diagnostics(_ line: String, _ code: String) {
        let (_, diagnostics) = rule(line)
        #expect(diagnostics.contains(code), "\(line) → \(diagnostics)")
    }
}

struct OtherSectionTests {
    @Test func hosts() {
        let parsed = fragment(
            """
            [Host]
            router.lan = 192.168.1.1
            static.example.com = 198.51.100.20, 2001:db8::20
            cdn.example.com = cdn.example.net
            *.corp.example.com = server:10.0.0.53
            doh.example.com = server:https://dns.example.net/dns-query
            sys.example.com = server:system
            bad.example.com = not a host
            bad2.example.com = server:nowhere
            """)
        #expect(parsed.hosts.count == 6)
        #expect(parsed.hosts[0].value == .addresses([IPAddress("192.168.1.1")!]))
        #expect(parsed.hosts[2].value == .alias(Hostname("cdn.example.net")!))
        #expect(parsed.hosts[3].isWildcard)
        #expect(codes(parsed.diagnostics) == ["CFG-040", "CFG-040"])
    }

    @Test func rewrites() {
        let parsed = fragment(
            #"""
            [URL Rewrite]
            ^https?://(www\.)?example\.com/old/(.*) https://example.com/new/$2 302
            ^https?://ads\.example\.com/ - reject-img
            ^https://a\.example\.com/ x teleport
            [Header Rewrite]
            ^https://api\.example\.com/ header-add X-Debug 1
            http-response ^https://api\.example\.com/ header-del Set-Cookie
            http-request ^https://api\.example\.com/ header-replace-regex User-Agent "^(.*)$" "$1 Aether"
            ^https://api\.example\.com/ header-explode X
            [Body Rewrite]
            http-response ^https://api\.example\.com/v1/config "\"ads\":true" "\"ads\":false" a b
            api\.example\.com missing-phase x
            [Map Local]
            ^https://api\.example\.com/v1/banner data-type=json data="{\"items\":[]}" header="X-A:1|X-B:2"
            ^https://img\.example\.com/pixel\.gif data-type=tiny-gif status-code=204
            ^https://f\.example\.com/ data-type=file data=https://files.example.com/a.json
            ^https://x\.example\.com/ data-type=hologram
            """#)
        #expect(parsed.urlRewrites.map(\.action) == [.found, .rejectImage])
        #expect(parsed.headerRewrites.count == 3)
        #expect(parsed.headerRewrites[1].phase == .response)
        #expect(
            parsed.headerRewrites[2].operation
                == .replaceRegex(name: "User-Agent", pattern: "^(.*)$", replacement: "$1 Aether"))
        #expect(parsed.bodyRewrites.count == 1)
        #expect(parsed.bodyRewrites[0].replacements.map(\.pattern) == [#""ads":true"#, "a"])
        #expect(parsed.mapLocals.count == 3)
        #expect(parsed.mapLocals[0].data == #"{"items":[]}"#)
        #expect(parsed.mapLocals[0].headers.count == 2)
        #expect(parsed.mapLocals[1].statusCode == 204)
        #expect(parsed.resources.map(\.kind) == [.mapLocalFile])
        #expect(codes(parsed.diagnostics) == ["CFG-050", "CFG-050", "CFG-050", "CFG-050"])
    }

    @Test func scripts() throws {
        let parsed = fragment(
            """
            [Script]
            fix = type=http-response, pattern=^https://api\\.example\\.com/, requires-body=true, max-size=262144, script-path=https://scripts.example.com/fix.js, timeout=5
            daily = type=cron, cronexp="0 9 * * 1-5", script-path=daily.js
            net = type=event, event-name=network-changed, script-path=net.js
            tool = type=generic, script-path=tool.js, argument=a=1&b=2, engine=webview
            dnsy = type=dns, script-path=d.js
            bad-cron = type=cron, cronexp="61 * * * *", script-path=x.js
            no-pattern = type=http-request, script-path=x.js
            no-type = script-path=x.js
            """)
        #expect(parsed.scripts.map(\.name) == ["fix", "daily", "net", "tool", "dnsy"])
        let fix = parsed.scripts[0]
        #expect(fix.requiresBody && fix.maxSize == 262144 && fix.timeout == 5)
        #expect(parsed.scripts[1].cronExpression?.daysOfWeek == [1, 2, 3, 4, 5])
        #expect(parsed.scripts[3].argument == "a=1&b=2")
        #expect(!parsed.scripts[4].isSupported)
        #expect(parsed.resources.map(\.url) == ["https://scripts.example.com/fix.js"])
        #expect(codes(parsed.diagnostics) == ["CFG-099", "CFG-099", "CFG-061", "CFG-060", "CFG-060"])
    }

    @Test func mitm() {
        let parsed = fragment(
            "[MITM]\nhostname = api.example.com, *.example.org, -secure.example.org, img.example.com:8443, *:8443, *, bad host\nskip-server-cert-verify = true\nca-p12 = MIIC\nh2 = true\nfoo = bar\n"
        )
        var sink = DiagnosticSink(file: "test.conf")
        let spec = MITMParser.parse(parsed.mitmEntries, sink: &sink)
        #expect(spec.hostnames.count == 6)
        #expect(spec.hostnames[2] == MITMSpec.HostnamePattern(host: "secure.example.org", port: nil, isExclusion: true))
        #expect(spec.hostnames[3].port == 8443)
        #expect(spec.skipServerCertVerify && spec.h2 && spec.caP12 == "MIIC")
        #expect(codes(sink.diagnostics) == ["CFG-070", "CFG-071", "CFG-099", "CFG-003"])
    }

    @Test func unknownAndModuleSections() {
        let profile = fragment("[Panel]\nx = 1\n[WireGuard home]\nprivate-key = k\n")
        #expect(codes(profile.diagnostics) == ["CFG-002", "CFG-002"])
        let module = fragment("[Proxy]\nA = direct\n[Rule]\nFINAL,DIRECT\n[Proxy]\nB = direct\n", module: true)
        #expect(codes(module.diagnostics) == ["CFG-080"])
        #expect(module.proxies.isEmpty && module.rules.count == 1)
    }
}

struct ExampleProfilesTests {
    @Test(arguments: ["full.conf", "minimal.conf"])
    func examplesHaveNoErrors(_ name: String) throws {
        let text = try String(contentsOf: Fixtures.examples.appendingPathComponent(name), encoding: .utf8)
        let parsed = fragment(text)
        #expect(!parsed.diagnostics.containsErrors, "\(parsed.diagnostics)")
        var sink = DiagnosticSink(file: name)
        var resources: [ExternalResourceRef] = []
        _ = GeneralParser.parse(parsed.generalEntries, sink: &sink, resources: &resources)
        _ = MITMParser.parse(parsed.mitmEntries, sink: &sink)
        #expect(!sink.diagnostics.containsErrors, "\(sink.diagnostics)")
    }

    @Test func fullExampleContents() throws {
        let text = try String(contentsOf: Fixtures.examples.appendingPathComponent("full.conf"), encoding: .utf8)
        let parsed = fragment(text)
        #expect(parsed.proxies.count == 10)
        #expect(parsed.groups.count == 6)
        #expect(parsed.rules.count == 20)
        #expect(parsed.hosts.count == 4)
        #expect(parsed.scripts.count == 5)
        #expect(parsed.rules.last?.condition == .final)
    }
}

struct CronExpressionTests {
    @Test func parsesFields() throws {
        let cron = try CronExpression("*/15 9-17 * JAN,jul MON-FRI")
        #expect(cron.minutes == [0, 15, 30, 45])
        #expect(cron.hours == Set(9...17))
        #expect(cron.months == [1, 7])
        #expect(cron.daysOfWeek == [1, 2, 3, 4, 5])
        #expect(cron.matches(minute: 30, hour: 9, day: 6, month: 1, weekday: 2))
        #expect(!cron.matches(minute: 31, hour: 9, day: 6, month: 1, weekday: 2))
        #expect(try CronExpression("0 0 * * 7").daysOfWeek == [0])
    }

    @Test func dayOfMonthAndWeekAreUnioned() throws {
        let cron = try CronExpression("0 0 1 * 1")
        #expect(cron.matches(minute: 0, hour: 0, day: 1, month: 3, weekday: 4))
        #expect(cron.matches(minute: 0, hour: 0, day: 9, month: 3, weekday: 1))
        #expect(!cron.matches(minute: 0, hour: 0, day: 9, month: 3, weekday: 2))
    }

    @Test(arguments: [
        "* * * *", "60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8", "5-1 * * * *", "*/0 * * * *",
        "a * * * *", ",1 * * * *",
    ])
    func rejects(_ text: String) {
        #expect(throws: CronExpression.ParseError.self) { try CronExpression(text) }
    }
}
