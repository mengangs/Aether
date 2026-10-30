import AetherDNS
import AetherFoundation
import AetherIPC
import AetherOutbound
import AetherProfile
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import AetherEngine

/// 假 DNS 上游：A 记录一律为 127.0.0.1（`nx` 中的域名返回 NXDOMAIN），AAAA 为空。
final class LoopbackDNSUpstream: DNSUpstream, @unchecked Sendable {
    let name = "loopback"
    let isSystem = false
    let nx: Set<String>
    let queries = NIOLockedValueBox<[String]>([])

    init(nx: Set<String> = []) {
        self.nx = nx
    }

    func send(_ query: [UInt8], on eventLoop: any EventLoop) -> EventLoopFuture<[UInt8]> {
        guard let message = try? DNSMessage.decode(query), let question = message.questions.first else {
            return eventLoop.makeFailedFuture(DNSError(.dnsMalformedResponse))
        }
        queries.withLockedValue { $0.append(question.name.normalized) }
        if nx.contains(question.name.normalized) {
            return eventLoop.makeSucceededFuture(DNSMessage.response(to: message, code: .nameError).encode())
        }
        let answers =
            question.type == .a
            ? [DNSResourceRecord(name: question.name, type: .a, ttl: 60, data: .a(IPv4Address(127, 0, 0, 1)))] : []
        return eventLoop.makeSucceededFuture(DNSMessage.response(to: message, answers: answers).encode())
    }
}

/// 路由集成测试的装置：路由背后的内部 SOCKS5 入站、HTTP 代理入站、回显源站，以及作为 `Proxy` 节点的上游 SOCKS5。
final class RouterHarness: Sendable {
    let threads: EngineThreads
    let echo: LoopbackTCPServer
    let upstreamAcceptor: DirectTestAcceptor
    let upstream: SOCKS5Inbound
    let router: Router
    let socks: SOCKS5Inbound
    let httpProxy: HTTPProxyInbound
    let dnsUpstream: LoopbackDNSUpstream
    static let credentials = SOCKS5Credentials(username: "hev", password: "secret")

    private init(
        threads: EngineThreads, echo: LoopbackTCPServer, upstreamAcceptor: DirectTestAcceptor, upstream: SOCKS5Inbound,
        router: Router, socks: SOCKS5Inbound, httpProxy: HTTPProxyInbound, dnsUpstream: LoopbackDNSUpstream
    ) {
        self.threads = threads
        self.echo = echo
        self.upstreamAcceptor = upstreamAcceptor
        self.upstream = upstream
        self.router = router
        self.socks = socks
        self.httpProxy = httpProxy
        self.dnsUpstream = dnsUpstream
    }

    /// `profile` 中的 `{UPSTREAM}` 替换为上游 SOCKS5 的端口。
    static func start(profile: String, nx: Set<String> = []) async throws -> RouterHarness {
        let threads = EngineThreads()
        let loop = threads.eventLoop
        let echo = try await LoopbackTCPServer.start(group: loop) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
        }
        let upstreamAcceptor = DirectTestAcceptor()
        let upstream = try await SOCKS5Inbound.start(on: loop, credentials: nil, acceptor: upstreamAcceptor).get()
        let text = profile.replacingOccurrences(of: "{UPSTREAM}", with: "\(upstream.port)")
        let resolved = ProfileResolver.resolve(profileText: text, fileName: "router.conf")
        #expect(!resolved.diagnostics.containsErrors, "\(resolved.diagnostics)")
        let configuration = RuntimeConfiguration.compile(resolved, profileName: "router")
        let dnsUpstream = LoopbackDNSUpstream(nx: nx)
        let router = try await loop.submit { () -> Router in
            let dns = DNSService(
                configuration: configuration.dns,
                environment: .init(eventLoop: loop, makeUpstream: { _ in dnsUpstream }))
            let dependencies = Router.Dependencies(
                flows: FlowManager(eventLoop: loop), dns: dns, rejects: RejectController(eventLoop: loop),
                requests: RequestLog(eventLoop: loop), policies: PolicyRegistry())
            return Router(eventLoop: loop, configuration: configuration, dependencies: dependencies)
        }.get()
        let socks = try await SOCKS5Inbound.start(on: loop, credentials: credentials, acceptor: router).get()
        let httpProxy = try await HTTPProxyInbound.start(on: loop, port: 0, delegate: router).get()
        return RouterHarness(
            threads: threads, echo: echo, upstreamAcceptor: upstreamAcceptor, upstream: upstream, router: router,
            socks: socks, httpProxy: httpProxy, dnsUpstream: dnsUpstream)
    }

    var echoPort: UInt16 { UInt16(echo.port) }

    /// 像 hev 一样经内部 SOCKS5 入站连接目标。
    func connect(_ destination: Destination) async throws -> (channel: any Channel, collector: CollectingHandler) {
        let connector = SOCKS5Connector(
            name: "hev", server: ProxyServer(host: "127.0.0.1", port: UInt16(socks.port)), username: "hev",
            password: "secret", udpEnabled: false)
        let context = DialContext(
            flowID: FlowID(rawValue: 0), eventLoop: threads.eventLoop, deadline: .now() + .seconds(15),
            serverResolver: FixedResolver(), logger: Logger(label: "test"))
        let channel = try await connector.connect(to: destination, context: context).get()
        let collector = CollectingHandler()
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandler(collector)
            try channel.syncOptions?.setOption(.autoRead, value: true)
            channel.read()
        }.get()
        return (channel, collector)
    }

    /// 发送并等待回显。
    func roundTrip(_ destination: Destination, _ text: String = "hello") async throws -> String {
        let (channel, collector) = try await connect(destination)
        try await channel.writeAndFlush(ByteBuffer(string: text))
        _ = await Poll.until { String(decoding: collector.bytes, as: UTF8.self).hasSuffix(text) }
        let result = String(decoding: collector.bytes, as: UTF8.self)
        try? await channel.close()
        return result
    }

    func records() async throws -> [RequestRecord] {
        let router = self.router
        return try await threads.eventLoop.submit { router.requests.recent + router.requests.activeRecords }.get()
    }

    /// 等待第 `index` 条（按 id）记录结束。
    func finishedRecord(_ index: Int = 0) async throws -> RequestRecord? {
        _ = await Poll.until { ((try? await self.records()) ?? []).filter { $0.state != .active }.count > index }
        return try await records().filter { $0.state != .active }.sorted { $0.id < $1.id }.dropFirst(index).first
    }

    /// 向路由背后的 DNS 服务查询 A 记录。
    func queryA(_ name: String) async throws -> IPAddress? {
        let router = self.router
        var message = DNSMessage(header: DNSHeader(id: 7))
        message.questions = [DNSQuestion(name: DNSName(name)!, type: .a)]
        let bytes = message.encode()
        let response = try await threads.eventLoop.flatSubmit { router.dns.answer(bytes, transport: .udp) }.get()
        return try response.flatMap { try DNSMessage.decode($0).answers.first?.address }
    }

    func stop() async throws {
        try await socks.close().get()
        try await httpProxy.close().get()
        try await upstream.close().get()
        try await echo.close()
        try await threads.shutdown()
    }
}

private let baseProfile = """
    [General]
    dns-server = 192.0.2.53

    [Proxy]
    Proxy = socks5, 127.0.0.1, {UPSTREAM}
    SS = ss, ss.example.com, 8388, encrypt-method=aes-128-gcm, password=test

    [Proxy Group]
    Select = select, Proxy, DIRECT
    Auto = url-test, Proxy, DIRECT, url=http://www.example.com/

    [Rule]
    DOMAIN,fake.example.com,DIRECT
    DOMAIN,rev.example.com,Proxy
    DOMAIN,sni.example.com,REJECT
    DOMAIN,drop.example.com,REJECT-DROP
    DOMAIN,gif.example.com,REJECT-TINYGIF
    DOMAIN,web.example.com,DIRECT
    DOMAIN,group.example.com,Select
    DOMAIN,ss.example.net,SS
    DOMAIN-SUFFIX,localhost,DIRECT
    IP-CIDR,127.0.0.0/8,Proxy
    FINAL,DIRECT,dns-failed
    """

@Suite("Router (06 §6, step by step)")
struct RouterTests {
    @Test("Step 1: request host, Fake IP recovery, unknown Fake IP (NET-010), DNS reverse lookup")
    func hostRecovery() async throws {
        let harness = try await RouterHarness.start(profile: baseProfile)
        // 请求中的域名。
        #expect(try await harness.roundTrip(.domain(Hostname("localhost")!, port: harness.echoPort)) == "hello")
        let first = try #require(try await harness.finishedRecord(0))
        #expect(first.hostSource == .request && first.host == "localhost")
        #expect(first.rule?.raw == "DOMAIN-SUFFIX,localhost,DIRECT")
        #expect(first.policyChain == ["DIRECT"])
        #expect(first.bytesUp == 5 && first.bytesDown == 5)

        // Fake IP：先经 DNS 拿到地址，再以该 IP 连接。
        let fake = try #require(try await harness.queryA("fake.example.com"))
        #expect(CIDR("198.18.0.0/15")!.contains(fake))
        #expect(try await harness.roundTrip(.ip(fake, port: harness.echoPort), "via fake") == "via fake")
        let second = try #require(try await harness.finishedRecord(1))
        #expect(second.hostSource == .fakeIP && second.host == "fake.example.com")
        #expect(second.rule?.raw == "DOMAIN,fake.example.com,DIRECT")

        // 未映射的 Fake IP：路由立即关闭连接（关闭可能早于客户端握手完成，这里以请求记录为准）。
        let (unknown, _) = try await harness.connect(.ip(IPAddress("198.18.200.200")!, port: 80))
        try? await unknown.close()
        let third = try #require(try await harness.finishedRecord(2))
        #expect(third.errorCode == "NET-010")

        // DNS 反查：路由解析过 rev.example.com → 127.0.0.1，之后以真实 IP 连接时恢复主机名并走 Proxy。
        _ = try await harness.threads.eventLoop.flatSubmit {
            harness.router.dns.resolve("rev.example.com", type: .a, purpose: .routing)
        }.get()
        #expect(try await harness.roundTrip(.ip(IPAddress("127.0.0.1")!, port: harness.echoPort), "rev") == "rev")
        let fourth = try #require(try await harness.finishedRecord(3))
        #expect(fourth.hostSource == .dnsReverse && fourth.host == "rev.example.com")
        #expect(fourth.policyChain == ["Proxy"])
        // 代理节点优先用域名：上游 SOCKS5 收到的是域名目标（远端解析）。
        #expect(
            harness.upstreamAcceptor.requests.withLockedValue { $0.last?.destination.hostname?.value }
                == "rev.example.com")
        try await harness.stop()
    }

    @Test("Step 2: sniffing TLS SNI and HTTP Host; sniffed bytes are replayed first")
    func sniffing() async throws {
        let harness = try await RouterHarness.start(profile: baseProfile)
        // TLS ClientHello 带 SNI sni.example.com → REJECT。
        let (tls, tlsCollector) = try await harness.connect(.ip(IPAddress("192.0.2.80")!, port: 443))
        try await tls.writeAndFlush(ByteBuffer(bytes: TestTLS.clientHello(serverName: "sni.example.com", alpn: ["h2"])))
        #expect(await Poll.until { tlsCollector.receivedEOF })
        let rejected = try #require(try await harness.finishedRecord(0))
        #expect(rejected.hostSource == .sniffed && rejected.host == "sni.example.com")
        #expect(rejected.appProtocol == .https)
        #expect(rejected.errorCode == "NET-022")

        // HTTP 请求头 Host: web.example.com → DIRECT；目标仍是原 IP，首包原样转发给源站。
        let request = "GET / HTTP/1.1\r\nHost: web.example.com\r\n\r\n"
        #expect(try await harness.roundTrip(.ip(IPAddress("127.0.0.1")!, port: harness.echoPort), request) == request)
        let sniffedHTTP = try #require(try await harness.finishedRecord(1))
        #expect(sniffedHTTP.hostSource == .sniffed && sniffedHTTP.host == "web.example.com")
        #expect(sniffedHTTP.appProtocol == .http)
        #expect(sniffedHTTP.policyChain == ["DIRECT"])
        try await harness.stop()
    }

    @Test("Step 3: outbound modes override the rules")
    func outboundModes() async throws {
        let harness = try await RouterHarness.start(profile: baseProfile)
        let router = harness.router
        try await harness.threads.eventLoop.submit { router.outboundMode = .direct }.get()
        // 规则会 REJECT，但直连模式一律 DIRECT。
        let request = "GET / HTTP/1.1\r\nHost: sni.example.com\r\n\r\n"
        #expect(try await harness.roundTrip(.ip(IPAddress("127.0.0.1")!, port: harness.echoPort), request) == request)
        let direct = try #require(try await harness.finishedRecord(0))
        #expect(direct.policyChain == ["DIRECT"] && direct.rule == nil)

        try await harness.threads.eventLoop.submit {
            router.outboundMode = .global
            router.globalPolicy = "Proxy"
        }.get()
        #expect(try await harness.roundTrip(.domain(Hostname("localhost")!, port: harness.echoPort), "g") == "g")
        let global = try #require(try await harness.finishedRecord(1))
        #expect(global.policyChain == ["Proxy"])
        try await harness.stop()
    }

    @Test("Step 4: IP rules trigger routing resolution; failures continue with dns-failed")
    func resolutionContinuation() async throws {
        let harness = try await RouterHarness.start(profile: baseProfile, nx: ["nx.example.com"])
        #expect(
            try await harness.roundTrip(.domain(Hostname("resolve.example.com")!, port: harness.echoPort)) == "hello")
        let resolved = try #require(try await harness.finishedRecord(0))
        #expect(resolved.rule?.raw == "IP-CIDR,127.0.0.0/8,Proxy")
        #expect(resolved.timings.dns != nil)
        #expect(harness.dnsUpstream.queries.withLockedValue { $0 }.contains("resolve.example.com"))

        let (failed, collector) = try await harness.connect(
            .domain(Hostname("nx.example.com")!, port: harness.echoPort))
        try await failed.writeAndFlush(ByteBuffer(string: "x"))
        _ = await Poll.until { collector.receivedEOF }
        try? await failed.close()
        let dnsFailed = try #require(try await harness.finishedRecord(1))
        #expect(dnsFailed.rule?.raw == "FINAL,DIRECT,dns-failed")
        #expect(dnsFailed.notes.contains("DNS resolution for routing failed"))
        try await harness.stop()
    }

    @Test("Step 5: policy resolution through groups; unavailable nodes fail with NET-020")
    func policyResolution() async throws {
        let harness = try await RouterHarness.start(profile: baseProfile)
        #expect(try await harness.roundTrip(.domain(Hostname("group.example.com")!, port: harness.echoPort)) == "hello")
        let viaGroup = try #require(try await harness.finishedRecord(0))
        #expect(viaGroup.policyChain == ["Select", "Proxy"])

        let router = harness.router
        let configuration = try await harness.threads.eventLoop.submit { router.configuration }.get()
        guard case .group(let select) = configuration.policies["Select"] else {
            Issue.record("Select missing")
            return
        }
        try harness.router.dependencies.policies.select("DIRECT", in: select)
        #expect(try await harness.roundTrip(.domain(Hostname("group.example.com")!, port: harness.echoPort)) == "hello")
        #expect(try await harness.finishedRecord(1)?.policyChain == ["Select", "DIRECT"])
        // 自动组在 M3-07 之前解析到第一个成员。
        #expect(try harness.router.dependencies.policies.resolve("Auto", in: configuration).chain == ["Auto", "Proxy"])

        let (unavailable, collector) = try await harness.connect(.domain(Hostname("ss.example.net")!, port: 443))
        #expect(await Poll.until { collector.receivedEOF })
        try? await unavailable.close()
        #expect(try await harness.finishedRecord(2)?.errorCode == "NET-020")
        try await harness.stop()
    }

    @Test("Step 6: reject policies close at once or hold the connection")
    func rejects() async throws {
        let harness = try await RouterHarness.start(profile: baseProfile)
        let (dropped, collector) = try await harness.connect(.domain(Hostname("drop.example.com")!, port: 80))
        try await dropped.writeAndFlush(ByteBuffer(string: "anything"))
        #expect(await Poll.until { (try? await harness.finishedRecord(0)) != nil })
        #expect(!collector.receivedEOF)
        let held = try await harness.threads.eventLoop.submit { harness.router.dependencies.rejects.heldConnections }
            .get()
        #expect(held == 1)
        #expect(try await harness.finishedRecord(0)?.errorCode == "NET-022")
        try await dropped.close()
        try await harness.stop()
    }

    @Test("DNS over TCP to the tunnel DNS address is answered without routing")
    func dnsOverTCP() async throws {
        let harness = try await RouterHarness.start(profile: baseProfile)
        let (channel, collector) = try await harness.connect(.ip(IPAddress("198.18.0.2")!, port: 53))
        var query = DNSMessage(header: DNSHeader(id: 0x5151))
        query.questions = [DNSQuestion(name: DNSName("tcp.example.com")!, type: .a)]
        let bytes = query.encode()
        var framed = ByteBuffer()
        framed.writeInteger(UInt16(bytes.count))
        framed.writeBytes(bytes)
        try await channel.writeAndFlush(framed)
        #expect(await Poll.until { collector.bytes.count > 2 })
        var buffer = ByteBuffer(bytes: collector.bytes)
        let frame = try #require(DNSStreamFraming.nextFrame(from: &buffer))
        let response = try DNSMessage.decode(frame)
        #expect(response.header.id == 0x5151)
        #expect(CIDR("198.18.0.0/15")!.contains(response.answers.first?.address ?? IPAddress("0.0.0.0")!))
        try await channel.close()
        try await harness.stop()
    }

    @Test("HTTP proxy inbound: absolute-form requests and CONNECT go through the router")
    func httpProxyThroughRouter() async throws {
        let harness = try await RouterHarness.start(profile: baseProfile)
        let collector = CollectingHandler()
        let client = try await ClientBootstrap(group: harness.threads.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
            }
            .connect(host: "127.0.0.1", port: harness.httpProxy.port).get()
        try await client.writeAndFlush(
            ByteBuffer(string: "GET http://gif.example.com/pixel.gif?id=1 HTTP/1.1\r\nHost: gif.example.com\r\n\r\n"))
        #expect(await Poll.until { String(decoding: collector.bytes, as: UTF8.self).contains("image/gif") })
        let gif = try #require(try await harness.finishedRecord(0))
        #expect(gif.url == "http://gif.example.com/pixel.gif")
        #expect(gif.method == "GET")
        #expect(gif.notes.contains("REJECT-TINYGIF"))
        #expect(gif.inbound == .httpProxy)

        try await client.writeAndFlush(
            ByteBuffer(string: "CONNECT localhost:\(harness.echoPort) HTTP/1.1\r\nHost: localhost\r\n\r\n"))
        #expect(
            await Poll.until { String(decoding: collector.bytes, as: UTF8.self).contains("200 Connection Established") }
        )
        try await client.writeAndFlush(ByteBuffer(string: "tunnel"))
        #expect(await Poll.until { String(decoding: collector.bytes, as: UTF8.self).hasSuffix("tunnel") })
        try await client.close()
        let connect = try #require(try await harness.finishedRecord(1))
        #expect(connect.inbound == .httpProxy && connect.host == "localhost")
        try await harness.stop()
    }
}

/// 构造测试用 TLS ClientHello。
enum TestTLS {
    static func clientHello(serverName: String, alpn: [String]) -> [UInt8] {
        var extensions: [UInt8] = []
        let name = Array(serverName.utf8)
        var sni: [UInt8] = [0]
        sni += [UInt8(name.count >> 8), UInt8(name.count & 0xFF)] + name
        let sniList = [UInt8(sni.count >> 8), UInt8(sni.count & 0xFF)] + sni
        extensions += [0, 0, UInt8(sniList.count >> 8), UInt8(sniList.count & 0xFF)] + sniList
        var protocols: [UInt8] = []
        for item in alpn {
            protocols += [UInt8(item.utf8.count)] + Array(item.utf8)
        }
        let alpnList = [UInt8(protocols.count >> 8), UInt8(protocols.count & 0xFF)] + protocols
        extensions += [0, 16, UInt8(alpnList.count >> 8), UInt8(alpnList.count & 0xFF)] + alpnList
        var body: [UInt8] = [3, 3] + Array(repeating: 0x11, count: 32)
        body += [0]  // session id
        body += [0, 2, 0x13, 0x01]  // cipher suites
        body += [1, 0]  // compression
        body += [UInt8(extensions.count >> 8), UInt8(extensions.count & 0xFF)] + extensions
        let handshake: [UInt8] = [1, 0, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
        return [0x16, 3, 1, UInt8(handshake.count >> 8), UInt8(handshake.count & 0xFF)] + handshake
    }
}
