import AetherFoundation
import AetherIPC
import AetherOutbound
import AetherProfile
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import AetherEngine

@Suite("Sniffer")
struct SnifferTests {
    @Test("TLS ClientHello yields SNI and ALPN, also when split across records and reads")
    func tls() {
        let hello = TestTLS.clientHello(serverName: "www.example.com", alpn: ["h2", "http/1.1"])
        #expect(Sniffer.sniff(hello) == .tls(serverName: "www.example.com", alpn: ["h2", "http/1.1"]))
        #expect(Sniffer.sniff(Array(hello.prefix(20))) == .needMoreData)
        // 拆成两个 TLS 记录。
        let handshake = Array(hello.dropFirst(5))
        let half = handshake.count / 2
        let first: [UInt8] = [0x16, 3, 1, UInt8(half >> 8), UInt8(half & 0xFF)] + handshake.prefix(half)
        let rest = handshake.count - half
        let second: [UInt8] = [0x16, 3, 1, UInt8(rest >> 8), UInt8(rest & 0xFF)] + handshake.suffix(rest)
        #expect(Sniffer.sniff(first) == .needMoreData)
        #expect(Sniffer.sniff(first + second) == .tls(serverName: "www.example.com", alpn: ["h2", "http/1.1"]))
        #expect(Sniffer.sniff([0x16, 3, 1, 0, 5, 2, 0, 0, 1, 0]) == .unknown)
    }

    @Test("HTTP request line and Host header")
    func http() {
        #expect(
            Sniffer.sniff(Array("GET /x HTTP/1.1\r\nHost: web.example.com:8080\r\n\r\n".utf8))
                == .http(host: "web.example.com"))
        #expect(
            Sniffer.sniff(Array("POST / HTTP/1.0\r\nhost: [2001:db8::1]:80\r\n\r\n".utf8)) == .http(host: "2001:db8::1")
        )
        #expect(Sniffer.sniff(Array("GET / HTTP/1.1\r\nAccept: */*\r\n\r\n".utf8)) == .http(host: nil))
        #expect(Sniffer.sniff(Array("GE".utf8)) == .needMoreData)
        #expect(Sniffer.sniff(Array("GET / HTTP/1.1\r\nHost: a".utf8)) == .needMoreData)
        #expect(Sniffer.sniff(Array("SSH-2.0-OpenSSH\r\n".utf8)) == .unknown)
        #expect(Sniffer.sniff([]) == .needMoreData)
    }

    @Test("Sniffing ends after the timeout with whatever arrived")
    func timeout() throws {
        let loop = EmbeddedEventLoop()
        let channel = EmbeddedChannel(loop: loop)
        try channel.connect(to: SocketAddress(ipAddress: "192.0.2.1", port: 1)).wait()
        let promise = loop.makePromise(of: (bytes: ByteBuffer, result: SniffResult).self)
        try channel.pipeline.syncOperations.addHandler(
            SniffHandler(initial: nil, timeout: .milliseconds(300), promise: promise))
        // "GE" 可能是 GET 的开头：继续等待，直到超时。
        try channel.writeInbound(ByteBuffer(string: "GE"))
        loop.advanceTime(by: .milliseconds(299))
        let done = NIOLockedValueBox(false)
        promise.futureResult.whenComplete { _ in done.withLockedValue { $0 = true } }
        #expect(!done.withLockedValue { $0 })
        loop.advanceTime(by: .milliseconds(1))
        let result = try promise.futureResult.wait()
        #expect(result.result == .unknown)
        #expect(result.bytes.readableBytes == 2)
    }
}

@Suite("Request log")
struct RequestLogTests {
    @Test("Finished records move into a bounded ring; pages follow the cursor")
    func ring() {
        let loop = EmbeddedEventLoop()
        let log = RequestLog(eventLoop: loop, capacity: 200)
        for index in 1...250 {
            log.start(
                RequestRecord(
                    id: UInt64(index), startedAt: log.now, inbound: .tun, transport: .tcp, destination: "192.0.2.1:80"))
        }
        #expect(log.activeRecords.count == 250)
        for index in 1...240 {
            log.finish(FlowID(rawValue: UInt64(index)), error: index % 2 == 0 ? NetworkError(.netConnectTimeout) : nil)
        }
        #expect(log.activeRecords.count == 10)
        let recent = log.recent
        #expect(recent.count == 200)
        #expect(recent.first?.id == 41 && recent.last?.id == 240)
        #expect(recent.first { $0.id == 42 }?.errorCode == "NET-002")
        #expect(recent.first { $0.id == 41 }?.state == .completed)

        let page = log.page(kind: .recent, sinceID: 230, limit: 5)
        #expect(page.records.map(\.id) == [231, 232, 233, 234, 235])
        #expect(page.next == 235)
        #expect(log.page(kind: .active, sinceID: nil, limit: 500).records.count == 10)

        log.shrinkForMemoryPressure()
        #expect(log.recent.count == 50)
        #expect(log.recent.last?.id == 240)
        log.finish(FlowID(rawValue: 241))
        #expect(log.recent.last?.id == 241)
    }

    @Test("Notes are capped at 20 entries of 200 characters")
    func notes() {
        var record = RequestRecord(id: 1, startedAt: .init(), inbound: .tun, transport: .tcp, destination: "x:1")
        for index in 0..<25 { record.addNote("\(index)" + String(repeating: "n", count: 300)) }
        #expect(record.notes.count == 20)
        #expect(record.notes.allSatisfy { $0.count == 200 })
        #expect(URLRedaction.stripQuery("http://example.com/a?b=c#d") == "http://example.com/a")
    }
}

@Suite("Runtime configuration and policy registry")
struct RuntimeConfigurationTests {
    private func compile(_ text: String) -> RuntimeConfiguration {
        RuntimeConfiguration.compile(ProfileResolver.resolve(profileText: text, fileName: "t.conf"))
    }

    private let profile = """
        [General]
        hijack-dns = *:53, 192.0.2.53:5353
        dns-server = 192.0.2.53, system

        [Proxy]
        HTTPS = https, proxy.example.com, 443, username=u, password=p, sni=cdn.example.net, skip-cert-verify=true
        S5 = socks5, 192.0.2.10, 1080, udp-relay=true
        VM = vmess, vmess.example.com, 443, username=0b4b5a3e-0000-4000-8000-000000000000
        Block = reject-tinygif

        [Proxy Group]
        Main = select, HTTPS, S5, DIRECT
        All = select, include-all-proxies=true
        Hidden = select, S5, hidden=true

        [Rule]
        FINAL,Main
        """

    @Test("Proxies become connectors; unsupported protocols are kept as unavailable nodes")
    func compileProxies() {
        let configuration = compile(profile)
        guard case .proxy(let https) = configuration.policies["HTTPS"] else {
            Issue.record("HTTPS missing")
            return
        }
        let connector = https.connector as? HTTPConnectConnector
        #expect(connector?.server.tls?.serverName == .custom("cdn.example.net"))
        #expect(connector?.server.tls?.skipCertificateVerification == true)
        #expect(connector?.username == "u")
        #expect(!https.supportsUDP)
        guard case .proxy(let socks) = configuration.policies["S5"],
            case .proxy(let vmess) = configuration.policies["VM"]
        else {
            Issue.record("nodes missing")
            return
        }
        #expect(socks.supportsUDP)
        #expect(vmess.connector == nil && vmess.unavailableReason != nil)
        guard case .reject(.tinyGIF) = configuration.policies["Block"] else {
            Issue.record("alias missing")
            return
        }
        guard case .group(let all) = configuration.policies["All"] else {
            Issue.record("group missing")
            return
        }
        #expect(all.members == ["HTTPS", "S5", "VM", "Block"])
        #expect(configuration.primarySelectGroups.map(\.name) == ["Main", "All"])
        #expect(configuration.dns.servers == ["192.0.2.53", "system"])
        #expect(configuration.isDNSTarget(IPAddress("198.18.0.2")!, port: 53))
        #expect(configuration.isDNSTarget(IPAddress("192.0.2.99")!, port: 53))
        #expect(configuration.isDNSTarget(IPAddress("192.0.2.53")!, port: 5353))
        #expect(!configuration.isDNSTarget(IPAddress("192.0.2.99")!, port: 5353))
        #expect(configuration.notes.contains { $0.contains("vmess") })
    }

    @Test("Shadowsocks AEAD nodes get connectors; 2022 methods and obfs=tls stay unavailable until M3-06")
    func compileShadowsocks() {
        let configuration = compile(
            """
            [Proxy]
            A = ss, ss.example.com, 8388, encrypt-method=chacha20-ietf-poly1305, password=pw, udp-relay=true, obfs=http, obfs-host=cdn.example.org
            B = ss, ss.example.com, 8389, encrypt-method=2022-blake3-aes-128-gcm, password=AAAAAAAAAAAAAAAAAAAAAA==
            C = ss, ss.example.com, 8390, encrypt-method=aes-128-gcm, password=pw, obfs=tls
            """)
        guard case .proxy(let aead) = configuration.policies["A"],
            case .proxy(let ss2022) = configuration.policies["B"],
            case .proxy(let obfsTLS) = configuration.policies["C"]
        else {
            Issue.record("nodes missing")
            return
        }
        let connector = aead.connector as? ShadowsocksConnector
        #expect(connector?.method == .chacha20IETFPoly1305)
        #expect(connector?.obfs == SimpleObfsHTTPOptions(host: "cdn.example.org", uri: "/"))
        #expect(connector?.server.port == 8388)
        #expect(aead.supportsUDP && connector?.capabilities.contains(.udp) == true)
        #expect(ss2022.connector == nil && ss2022.unavailableReason?.contains("M3-06") == true)
        #expect(obfsTLS.connector == nil && obfsTLS.unavailableReason?.contains("obfs tls") == true)
    }

    @Test("Trojan nodes always use TLS and carry ws-path / ws-headers when ws=true")
    func compileTrojan() {
        let configuration = compile(
            """
            [Proxy]
            T = trojan, trojan.example.com, 443, password=pw, sni=cdn.example.net, udp-relay=true
            W = trojan, trojan.example.com, 443, password=pw, ws=true, ws-path=/tj, ws-headers="Host:front.example.org"
            """)
        guard case .proxy(let plain) = configuration.policies["T"], case .proxy(let ws) = configuration.policies["W"]
        else {
            Issue.record("nodes missing")
            return
        }
        let tls = plain.connector as? TrojanConnector
        #expect(tls?.server.tls?.serverName == .custom("cdn.example.net"))
        #expect(tls?.server.webSocket == nil)
        #expect(plain.supportsUDP && tls?.capabilities.contains(.udp) == true)
        let overWS = ws.connector as? TrojanConnector
        #expect(overWS?.server.tls != nil)
        #expect(
            overWS?.server.webSocket
                == WebSocketClientOptions(path: "/tj", headers: [.init(name: "Host", value: "front.example.org")]))
        #expect(!ws.supportsUDP)
    }

    @Test("VLESS nodes need tls=true and a valid UUID")
    func compileVLESS() {
        let configuration = compile(
            """
            [Proxy]
            V = vless, vless.example.com, 443, username=b831381d-6324-4d53-ad4f-8cda48b30811, tls=true, ws=true, ws-path=/v, udp-relay=true
            P = vless, vless.example.com, 443, username=b831381d-6324-4d53-ad4f-8cda48b30811
            """)
        guard case .proxy(let ok) = configuration.policies["V"], case .proxy(let plain) = configuration.policies["P"]
        else {
            Issue.record("nodes missing")
            return
        }
        let connector = ok.connector as? VLESSConnector
        #expect(connector?.server.tls != nil && connector?.server.webSocket?.path == "/v")
        #expect(ok.supportsUDP)
        #expect(plain.connector == nil && plain.unavailableReason?.contains("tls=true") == true)
    }

    @Test("Node identity changes with credentials but not with the name")
    func identity() {
        let a = compile("[Proxy]\nA = socks5, 192.0.2.1, 1080, username=u, password=one\n[Rule]\nFINAL,A")
        let b = compile("[Proxy]\nB = socks5, 192.0.2.1, 1080, username=u, password=one\n[Rule]\nFINAL,B")
        let c = compile("[Proxy]\nA = socks5, 192.0.2.1, 1080, username=u, password=two\n[Rule]\nFINAL,A")
        func identity(_ configuration: RuntimeConfiguration, _ name: String) -> String? {
            if case .proxy(let node) = configuration.policies[name] { return node.identity }
            return nil
        }
        #expect(identity(a, "A") == identity(b, "B"))
        #expect(identity(a, "A") != identity(c, "A"))
        #expect(identity(a, "A")?.contains("one") == false)
    }

    @Test("Selections fall back to the first member and reject unknown members")
    func selections() throws {
        let configuration = compile(profile)
        let registry = PolicyRegistry(selections: ["Main": "Gone"])
        #expect(try registry.resolve("Main", in: configuration).chain == ["Main", "HTTPS"])
        guard case .group(let main) = configuration.policies["Main"] else {
            Issue.record("Main missing")
            return
        }
        try registry.select("S5", in: main)
        #expect(try registry.resolve("Main", in: configuration).chain == ["Main", "S5"])
        #expect(throws: NetworkError.self) { try registry.select("Nope", in: main) }
        #expect(throws: NetworkError.self) { try registry.resolve("Missing", in: configuration) }
    }
}
