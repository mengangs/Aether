import AetherFoundation
import AetherOutbound
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import AetherHTTP

/// 按路径回放原始应答的 HTTP 服务端：读到请求头结束后写出 `chunks`（逐块 flush），`close` 时随后关闭连接。
private final class ScriptedHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    struct Reply: Sendable {
        var chunks: [[UInt8]]
        var close = true
    }

    let routes: @Sendable (_ path: String) -> Reply?
    let requests: NIOLockedValueBox<[[String]]>
    private var buffer: [UInt8] = []
    private var answered = false

    init(routes: @escaping @Sendable (String) -> Reply?, requests: NIOLockedValueBox<[[String]]>) {
        self.routes = routes
        self.requests = requests
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !answered else { return }
        buffer += unwrapInboundIn(data).readableBytesView
        guard let end = String(decoding: buffer, as: UTF8.self).range(of: "\r\n\r\n") else { return }
        answered = true
        let text = String(String(decoding: buffer, as: UTF8.self)[..<end.lowerBound])
        let lines = text.components(separatedBy: "\r\n")
        requests.withLockedValue { $0.append(lines) }
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        guard let reply = routes(path) else {
            return  // 不应答（超时测试）
        }
        for chunk in reply.chunks {
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: chunk)), promise: nil)
        }
        if reply.close {
            context.close(promise: nil)
        }
    }
}

private func raw(_ text: String) -> [UInt8] { Array(text.utf8) }

private func response(_ status: String, headers: [String] = [], body: [UInt8] = [], length: Int? = nil) -> [UInt8] {
    var head = "HTTP/1.1 \(status)\r\n"
    for header in headers { head += header + "\r\n" }
    head += "Content-Length: \(length ?? body.count)\r\n\r\n"
    return raw(head) + body
}

private struct FetchHarness {
    let group: MultiThreadedEventLoopGroup
    let server: LoopbackTCPServer
    let requests: NIOLockedValueBox<[[String]]>
    let certificates: TestCertificates?

    static func start(
        tls: Bool = false, routes: @escaping @Sendable (_ path: String, _ port: Int) -> ScriptedHTTPHandler.Reply?
    ) async throws -> FetchHarness {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let requests = NIOLockedValueBox<[[String]]>([])
        let port = NIOLockedValueBox(0)
        var context: NIOSSLContext?
        var certificates: TestCertificates?
        if tls {
            let made = try TestCertificates.make(dnsNames: ["files.example.com"])
            var configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: [.certificate(try NIOSSLCertificate(bytes: made.leafDER, format: .der))],
                privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(made.leafKeyPEM.utf8), format: .pem)))
            configuration.shutdownTimeout = .milliseconds(50)
            context = try NIOSSLContext(configuration: configuration)
            certificates = made
        }
        let sslContext = context
        let server = try await LoopbackTCPServer.start(group: group) { channel in
            channel.eventLoop.makeCompletedFuture {
                if let sslContext {
                    try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: sslContext))
                }
                let current = port.withLockedValue { $0 }
                try channel.pipeline.syncOperations.addHandler(
                    ScriptedHTTPHandler(routes: { routes($0, current) }, requests: requests))
            }
        }
        port.withLockedValue { $0 = server.port }
        return FetchHarness(group: group, server: server, requests: requests, certificates: certificates)
    }

    /// 任何目标都连到回环服务端。
    func fetch(
        _ url: String, headers: [(String, String)] = [], limit: Int = 1 << 20, timeout: TimeAmount = .seconds(5)
    ) async throws -> HTTPFetch.Response {
        let loop = group.next()
        let port = server.port
        var tls = TLSClientOptions()
        if let certificates {
            tls.additionalTrustRootsPEM = [certificates.caPEM]
        }
        return try await HTTPFetch.get(
            url, headers: headers, limit: limit, timeout: timeout, tls: tls, on: loop
        ) { _, _ in
            ClientBootstrap(group: loop).channelOption(.allowRemoteHalfClosure, value: true)
                .connect(host: "127.0.0.1", port: port)
        }.get()
    }

    func stop() async throws {
        try await server.close()
        try await group.shutdownGracefully()
    }
}

private func code(of error: any Error) -> AetherErrorCode? {
    (error as? any AetherErrorProtocol)?.code
}

@Suite("HTTP fetch for external resources (11 §5.3)")
struct HTTPFetchTests {
    @Test("Content-Length, chunked and read-until-close bodies; request headers are sent")
    func bodies() async throws {
        let harness = try await FetchHarness.start { path, _ in
            switch path {
            case "/length?x=1":
                return .init(chunks: [response("200 OK", headers: ["ETag: \"v1\""], body: raw("DOMAIN,example.com\n"))])
            case "/chunked":
                return .init(chunks: [
                    raw("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n"),
                    raw("6\r\n world\r\n0\r\n\r\n"),
                ])
            case "/close":
                return .init(chunks: [raw("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\npart one, "), raw("part two")])
            case "/304":
                return .init(chunks: [raw("HTTP/1.1 304 Not Modified\r\nETag: \"v1\"\r\n\r\n")])
            default:
                return .init(chunks: [response("404 Not Found")])
            }
        }
        let first = try await harness.fetch(
            "http://files.example.com/length?x=1",
            headers: [("User-Agent", "Aether/0.4.0"), ("If-None-Match", "\"v0\"")])
        #expect(first.status == 200)
        #expect(first.body == raw("DOMAIN,example.com\n"))
        #expect(first.header("etag") == "\"v1\"")
        let request = try #require(harness.requests.withLockedValue { $0.first })
        #expect(request.first == "GET /length?x=1 HTTP/1.1")
        #expect(request.contains("Host: files.example.com"))
        #expect(request.contains("User-Agent: Aether/0.4.0"))
        #expect(request.contains("If-None-Match: \"v0\""))
        #expect(request.contains("Connection: close"))
        #expect(try await harness.fetch("http://files.example.com/chunked").body == raw("hello world"))
        #expect(try await harness.fetch("http://files.example.com/close").body == raw("part one, part two"))
        let notModified = try await harness.fetch("http://files.example.com/304")
        #expect(notModified.status == 304)
        #expect(notModified.body.isEmpty)
        #expect(try await harness.fetch("http://files.example.com/missing").status == 404)
        try await harness.stop()
    }

    @Test("Relative and absolute redirects are followed up to 5 times; the final URL is reported")
    func redirects() async throws {
        let harness = try await FetchHarness.start { path, port in
            switch path {
            case "/a": return .init(chunks: [response("302 Found", headers: ["Location: b?step=2"])])
            case "/b?step=2":
                return .init(chunks: [
                    response("301 Moved Permanently", headers: ["Location: http://mirror.example.net:\(port)/c"])
                ])
            case "/c": return .init(chunks: [response("200 OK", body: raw("final"))])
            case "/loop": return .init(chunks: [response("307 Temporary Redirect", headers: ["Location: /loop"])])
            default: return nil
            }
        }
        let port = harness.server.port
        let result = try await harness.fetch("http://files.example.com:\(port)/a")
        #expect(result.body == raw("final"))
        #expect(result.url == "http://mirror.example.net:\(port)/c")
        #expect(
            harness.requests.withLockedValue { $0.map { $0[0] } } == [
                "GET /a HTTP/1.1", "GET /b?step=2 HTTP/1.1", "GET /c HTTP/1.1",
            ])
        #expect(harness.requests.withLockedValue { $0[2] }.contains("Host: mirror.example.net:\(port)"))
        await #expect {
            try await harness.fetch("http://files.example.com/loop")
        } throws: { error in
            code(of: error) == .resDownloadFailed && "\(error)".contains("Too many redirects")
        }
        #expect(harness.requests.withLockedValue { $0.count } == 3 + 6)
        try await harness.stop()
    }

    @Test("Bodies over the limit fail with RES-010; truncated bodies and silence fail without hanging")
    func failures() async throws {
        let harness = try await FetchHarness.start { path, _ in
            switch path {
            case "/declared": return .init(chunks: [response("200 OK", body: [UInt8](repeating: 0x61, count: 2048))])
            case "/chunked":
                return .init(chunks: [
                    raw("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"),
                    raw("400\r\n") + [UInt8](repeating: 0x61, count: 1024) + raw("\r\n"),
                    raw("400\r\n") + [UInt8](repeating: 0x62, count: 1024) + raw("\r\n0\r\n\r\n"),
                ])
            case "/truncated": return .init(chunks: [response("200 OK", body: raw("short"), length: 100)])
            case "/garbage": return .init(chunks: [raw("SSH-2.0-OpenSSH\r\n\r\n")])
            default: return nil
            }
        }
        for path in ["/declared", "/chunked"] {
            await #expect {
                try await harness.fetch("http://files.example.com\(path)", limit: 1500)
            } throws: { code(of: $0) == .resTooLarge }
        }
        #expect(try await harness.fetch("http://files.example.com/chunked", limit: 2048).body.count == 2048)
        await #expect {
            try await harness.fetch("http://files.example.com/truncated")
        } throws: { code(of: $0) == .netConnectionReset || code(of: $0) == .netProtocolError }
        await #expect {
            try await harness.fetch("http://files.example.com/garbage")
        } throws: { code(of: $0) == .netProtocolError || code(of: $0) == .netConnectionReset }
        await #expect {
            try await harness.fetch("http://files.example.com/silent", timeout: .milliseconds(200))
        } throws: { code(of: $0) == .netConnectTimeout }
        await #expect {
            try await harness.fetch("ftp://files.example.com/x")
        } throws: { code(of: $0) == .resDownloadFailed }
        try await harness.stop()
    }

    @Test("HTTPS is verified against the trust roots; redirects from HTTPS to HTTP are refused")
    func https() async throws {
        let harness = try await FetchHarness.start(tls: true) { path, port in
            switch path {
            case "/list": return .init(chunks: [response("200 OK", body: raw(".example.org\n"))])
            case "/down":
                return .init(chunks: [
                    response("302 Found", headers: ["Location: http://files.example.com:\(port)/list"])
                ])
            default: return nil
            }
        }
        let port = harness.server.port
        #expect(try await harness.fetch("https://files.example.com:\(port)/list").body == raw(".example.org\n"))
        await #expect {
            try await harness.fetch("https://files.example.com:\(port)/down")
        } throws: { "\($0)".contains("HTTPS to HTTP") }
        // 证书主机名不符。
        await #expect(throws: (any Error).self) {
            try await harness.fetch("https://other.example.com:\(port)/list")
        }
        try await harness.stop()
    }
}
