import AetherFoundation
import AetherHTTP
import AetherOutbound
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import Testing

@testable import AetherEngine

/// 源站：响应体描述它看到的请求（方法、目标、Host、是否带 Proxy-Connection、请求体长度），带 Content-Length，支持 keep-alive。
private final class OriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let name: String
    private var head: HTTPRequestHead?
    private var bodyBytes = 0

    init(name: String) {
        self.name = name
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            bodyBytes = 0
        case .body(let buffer):
            bodyBytes += buffer.readableBytes
        case .end:
            guard let head else { return }
            let proxyHeader = head.headers.contains(name: "proxy-connection") ? "yes" : "no"
            let body =
                "\(name) \(head.method.rawValue) \(head.uri) host=\(head.headers.first(name: "host") ?? "-") "
                + "proxy=\(proxyHeader) body=\(bodyBytes)"
            var headers = HTTPHeaders()
            headers.add(name: "Content-Length", value: "\(body.utf8.count)")
            headers.add(name: "Keep-Alive", value: "timeout=5")
            context.write(
                wrapOutboundOut(.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers))), promise: nil
            )
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: body)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

/// 记录交换结果的观察者。
private final class RecordingObserver: HTTPExchangeObserver, @unchecked Sendable {
    let events: NIOLockedValueBox<[String]>

    init(events: NIOLockedValueBox<[String]>) {
        self.events = events
    }

    func upstreamConnected(remoteAddress: String?) { events.withLockedValue { $0.append("connected") } }
    func responseStarted(status: Int) { events.withLockedValue { $0.append("status \(status)") } }
    func transferred(up: Int, down: Int) {}
    func finished(error: (any AetherErrorProtocol)?) {
        events.withLockedValue { $0.append("finished \(error?.code.rawValue ?? "ok")") }
    }
}

/// 测试决策方：按主机名决定转发、拒绝或失败，转发时直接连到 127.0.0.1。
private final class TestProxyDelegate: HTTPProxyDelegate, @unchecked Sendable {
    let dials = NIOLockedValueBox(0)
    let events = NIOLockedValueBox<[String]>([])
    let routed = NIOLockedValueBox<[HTTPRouteRequest]>([])
    let closedPort: Int

    init(closedPort: Int) {
        self.closedPort = closedPort
    }

    private func dial(_ destination: Destination, on loop: any EventLoop) -> EventLoopFuture<any Channel> {
        dials.withLockedValue { $0 += 1 }
        let port = destination.hostText == "down.example" ? closedPort : Int(destination.port)
        return ChannelTuning.configure(ClientBootstrap(group: loop))
            .connect(host: "127.0.0.1", port: port)
            .map { $0 as any Channel }
    }

    func connect(
        _ destination: Destination, channel: any Channel, initialData: ByteBuffer?, replier: HTTPConnectReplier
    ) {
        dial(destination, on: channel.eventLoop).whenComplete { result in
            switch result {
            case .success(let outbound):
                replier.established().whenComplete { _ in
                    _ = try? FlowRelay.glue(
                        inbound: channel, outbound: outbound, counters: FlowCounters(), initialUpload: initialData)
                }
            case .failure:
                replier.fail(status: .badGateway)
            }
        }
    }

    func route(_ request: HTTPRouteRequest, channel: any Channel) -> EventLoopFuture<HTTPRouteDecision> {
        routed.withLockedValue { $0.append(request) }
        let observer = RecordingObserver(events: events)
        let loop = channel.eventLoop
        switch request.destination.hostText {
        case "blocked.example":
            return loop.makeSucceededFuture(.reject(.forbidden(errorPage: false), observer: observer))
        case "gif.example":
            return loop.makeSucceededFuture(.reject(.tinyGIF, observer: observer))
        default:
            let destination = request.destination
            return loop.makeSucceededFuture(
                .forward(
                    HTTPForwardPlan(
                        reuseKey: destination.description, dial: { self.dial(destination, on: loop) },
                        observer: observer)))
        }
    }
}

private struct ProxyFixture {
    let threads: EngineThreads
    let originA: LoopbackTCPServer
    let originB: LoopbackTCPServer
    let echo: LoopbackTCPServer
    let delegate: TestProxyDelegate
    let inbound: HTTPProxyInbound

    static func start() async throws -> ProxyFixture {
        let threads = EngineThreads()
        func origin(_ name: String) async throws -> LoopbackTCPServer {
            try await LoopbackTCPServer.start(group: threads.group) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(OriginHandler(name: name))
                }
            }
        }
        let originA = try await origin("A")
        let originB = try await origin("B")
        let echo = try await LoopbackTCPServer.start(group: threads.group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
        }
        // 找一个已关闭的端口：绑定后立即关闭。
        let probe = try await LoopbackTCPServer.start(group: threads.group) { $0.eventLoop.makeSucceededVoidFuture() }
        let closedPort = probe.port
        try await probe.close()
        let delegate = TestProxyDelegate(closedPort: closedPort)
        let inbound = try await HTTPProxyInbound.start(on: threads.eventLoop, port: 0, delegate: delegate).get()
        return ProxyFixture(
            threads: threads, originA: originA, originB: originB, echo: echo, delegate: delegate, inbound: inbound)
    }

    func client() async throws -> (channel: any Channel, collector: CollectingHandler) {
        let collector = CollectingHandler()
        let channel = try await ClientBootstrap(group: threads.group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
            }
            .connect(host: "127.0.0.1", port: inbound.port).get()
        return (channel, collector)
    }

    func stop() async throws {
        try await inbound.close().get()
        try await originA.close()
        try await originB.close()
        try await echo.close()
        try await threads.shutdown()
    }
}

private func text(_ collector: CollectingHandler) -> String {
    String(decoding: collector.bytes, as: UTF8.self)
}

private func occurrences(of needle: String, in haystack: String) -> Int {
    haystack.components(separatedBy: needle).count - 1
}

@Suite("HTTP proxy inbound")
struct HTTPProxyInboundTests {
    @Test("Absolute-form requests are routed one by one, rewritten to origin form and stripped of hop-by-hop headers")
    func forwardsPerRequest() async throws {
        let fixture = try await ProxyFixture.start()
        let (client, collector) = try await fixture.client()
        let a = fixture.originA.port
        let b = fixture.originB.port
        let requests =
            "GET http://localhost:\(a)/one?x=1 HTTP/1.1\r\nHost: localhost:\(a)\r\nProxy-Connection: keep-alive\r\n"
            + "User-Agent: AetherTest/1\r\n\r\n"
            + "GET http://localhost:\(a)/two HTTP/1.1\r\nHost: localhost:\(a)\r\n\r\n"
            + "POST http://127.0.0.1:\(b)/three HTTP/1.1\r\nHost: 127.0.0.1:\(b)\r\nContent-Length: 5\r\n\r\nhello"
        try await client.writeAndFlush(ByteBuffer(string: requests))
        #expect(
            await Poll.until {
                occurrences(of: "HTTP/1.1 200 OK", in: text(collector)) == 3 && text(collector).contains("body=5")
            })
        let output = text(collector)
        #expect(output.contains("A GET /one?x=1 host=localhost:\(a) proxy=no body=0"))
        #expect(output.contains("A GET /two host=localhost:\(a) proxy=no body=0"))
        #expect(output.contains("B POST /three host=127.0.0.1:\(b) proxy=no body=5"))
        #expect(!output.lowercased().contains("keep-alive: timeout"))
        // 同一目标复用上游连接：A 两个请求只拨号一次，B 一次。
        #expect(fixture.delegate.dials.withLockedValue { $0 } == 2)
        let routed = fixture.delegate.routed.withLockedValue { $0 }
        #expect(
            routed.map(\.url) == [
                "http://localhost:\(a)/one?x=1", "http://localhost:\(a)/two", "http://127.0.0.1:\(b)/three",
            ])
        #expect(routed.first?.userAgent == "AetherTest/1")
        #expect(routed.first?.destination == .domain(Hostname("localhost")!, port: UInt16(a)))
        #expect(
            await Poll.until {
                fixture.delegate.events.withLockedValue { $0.filter { $0 == "finished ok" }.count } == 3
            })
        try await client.close()
        try await fixture.stop()
    }

    @Test("Origin-form requests get 400 and the connection is closed")
    func originFormRejected() async throws {
        let fixture = try await ProxyFixture.start()
        let (client, collector) = try await fixture.client()
        try await client.writeAndFlush(ByteBuffer(string: "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n"))
        #expect(await Poll.until { collector.isClosed })
        #expect(text(collector).hasPrefix("HTTP/1.1 400 Bad Request"))
        #expect(fixture.delegate.routed.withLockedValue { $0.isEmpty })
        try await fixture.stop()
    }

    @Test("Reject policies answer 403 and a 1x1 GIF on the same keep-alive connection")
    func rejectResponses() async throws {
        let fixture = try await ProxyFixture.start()
        let (client, collector) = try await fixture.client()
        try await client.writeAndFlush(
            ByteBuffer(
                string: "GET http://blocked.example/ad.js HTTP/1.1\r\nHost: blocked.example\r\n\r\n"
                    + "GET http://gif.example/pixel HTTP/1.1\r\nHost: gif.example\r\n\r\n"))
        #expect(await Poll.until { text(collector).contains("image/gif") && collector.bytes.count > 150 })
        let output = text(collector)
        #expect(output.hasPrefix("HTTP/1.1 403 Forbidden"))
        #expect(output.contains("HTTP/1.1 200 OK"))
        #expect(output.lowercased().contains("content-length: 42"))
        #expect(collector.bytes.suffix(42) == [UInt8](TinyGIFBytes.value))
        #expect(!collector.isClosed)
        #expect(fixture.delegate.dials.withLockedValue { $0 } == 0)
        try await client.close()
        try await fixture.stop()
    }

    @Test("A failed dial answers 502")
    func badGateway() async throws {
        let fixture = try await ProxyFixture.start()
        let (client, collector) = try await fixture.client()
        try await client.writeAndFlush(
            ByteBuffer(string: "GET http://down.example/ HTTP/1.1\r\nHost: down.example\r\n\r\n"))
        #expect(await Poll.until { text(collector).contains("NET-") })
        #expect(text(collector).hasPrefix("HTTP/1.1 502 Bad Gateway"))
        #expect(
            await Poll.until {
                fixture.delegate.events.withLockedValue { $0.contains { $0.hasPrefix("finished NET-") } }
            })
        // 出错后入站关闭了连接。
        #expect(await Poll.until { collector.isClosed })
        try? await client.close()
        try await fixture.stop()
    }

    @Test("CONNECT answers 200 only after the outbound is up and then relays raw bytes")
    func connectTunnel() async throws {
        let fixture = try await ProxyFixture.start()
        let (client, collector) = try await fixture.client()
        try await client.writeAndFlush(
            ByteBuffer(
                string:
                    "CONNECT localhost:\(fixture.echo.port) HTTP/1.1\r\nHost: localhost:\(fixture.echo.port)\r\n\r\n"))
        let established = "HTTP/1.1 200 Connection Established\r\n\r\n"
        #expect(await Poll.until { text(collector) == established })
        try await client.writeAndFlush(ByteBuffer(string: "\u{16}\u{3}\u{1}tls-bytes"))
        #expect(await Poll.until { text(collector) == established + "\u{16}\u{3}\u{1}tls-bytes" })
        try await client.close()

        let (failing, failingCollector) = try await fixture.client()
        try await failing.writeAndFlush(ByteBuffer(string: "CONNECT down.example:443 HTTP/1.1\r\n\r\n"))
        #expect(await Poll.until { failingCollector.isClosed })
        #expect(text(failingCollector).hasPrefix("HTTP/1.1 502 Bad Gateway"))
        try await fixture.stop()
    }
}

/// 与 AetherHTTP 内部 GIF 相同的字节（测试独立声明，避免依赖内部符号）。
private enum TinyGIFBytes {
    static let value: [UInt8] = [
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF,
        0xFF, 0x21, 0xF9, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00,
        0x00, 0x02, 0x01, 0x44, 0x00, 0x3B,
    ]
}
