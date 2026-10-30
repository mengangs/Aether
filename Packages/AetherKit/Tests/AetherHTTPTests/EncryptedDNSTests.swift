import AetherFoundation
import AetherOutbound
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOPosix
import NIOSSL
import Testing

@testable import AetherHTTP

/// 固定表解析器（只解析 dns.example.com）。
private struct LoopbackResolver: ServerAddressResolver {
    func resolve(_ host: String, family: AddressFamily, on eventLoop: any EventLoop) -> EventLoopFuture<[IPAddress]> {
        eventLoop.makeSucceededFuture(host == "dns.example.com" && family == .v4 ? [IPAddress("127.0.0.1")!] : [])
    }
}

/// `name A` 查询，ID 为 `id`。
private func query(_ name: String, id: UInt16) -> [UInt8] {
    var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
    for label in name.split(separator: ".") {
        bytes.append(UInt8(label.utf8.count))
        bytes += Array(label.utf8)
    }
    bytes += [0, 0, 1, 0, 1]
    return bytes
}

/// 回答 A 记录：地址的最后一字节为问题名的文本长度（便于区分不同查询；编码后的名字比文本长 2 字节）。
private func answer(_ query: [UInt8]) -> [UInt8] {
    var reply = Array(query[0..<2]) + [0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
    reply += query[12...]
    reply += [0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, UInt8(min(query.count - 18, 255))]
    return reply
}

private func lastOctet(_ reply: [UInt8]) -> UInt8? { reply.last }

private func serverContext(alpn: [String]) throws -> (NIOSSLContext, TestCertificates) {
    let certificates = try TestCertificates.make(dnsNames: ["dns.example.com"])
    var configuration = TLSConfiguration.makeServerConfiguration(
        certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificates.leafDER, format: .der))],
        privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(certificates.leafKeyPEM.utf8), format: .pem)))
    configuration.applicationProtocols = alpn
    // 测试结束时不等待对端的 close_notify（默认 5 秒）。
    configuration.shutdownTimeout = .milliseconds(50)
    return (try NIOSSLContext(configuration: configuration), certificates)
}

private func clientTLS(_ certificates: TestCertificates) -> TLSClientOptions {
    var tls = TLSClientOptions()
    tls.additionalTrustRootsPEM = [certificates.caPEM]
    return tls
}

// MARK: - DoT 服务端

/// 2 字节长度分帧；`batch` 个查询到齐后倒序回答（验证流水线中的 ID 对应）；`closeAfter` 个应答后关闭连接。
private final class DoTServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let batch: Int
    let closeAfter: Int?
    let ids: NIOLockedValueBox<[UInt16]>
    private var buffer = ByteBuffer()
    private var waiting: [[UInt8]] = []
    private var answered = 0

    init(batch: Int, closeAfter: Int?, ids: NIOLockedValueBox<[UInt16]>) {
        self.batch = batch
        self.closeAfter = closeAfter
        self.ids = ids
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self),
            buffer.readableBytes >= 2 + Int(length)
        {
            buffer.moveReaderIndex(forwardBy: 2)
            let message = buffer.readBytes(length: Int(length)) ?? []
            ids.withLockedValue { $0.append(UInt16(message[0]) << 8 | UInt16(message[1])) }
            waiting.append(message)
        }
        guard waiting.count >= batch else { return }
        for message in waiting.reversed() {
            let reply = answer(message)
            var out = context.channel.allocator.buffer(capacity: reply.count + 2)
            out.writeInteger(UInt16(reply.count))
            out.writeBytes(reply)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
            answered += 1
        }
        waiting.removeAll()
        if let closeAfter, answered >= closeAfter {
            context.close(promise: nil)
        }
    }
}

// MARK: - DoH 服务端

/// 收集一个 POST 请求，回答 `status`（200 时正文为应答）。记录请求的方法、路径、类型与报文 ID。
private final class DoHServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    struct Seen: Sendable {
        var method: String
        var uri: String
        var contentType: String?
        var id: UInt16
    }

    let status: HTTPResponseStatus
    let seen: NIOLockedValueBox<[Seen]>
    private var head: HTTPRequestHead?
    private var body: [UInt8] = []

    init(status: HTTPResponseStatus, seen: NIOLockedValueBox<[Seen]>) {
        self.status = status
        self.seen = seen
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let request):
            head = request
            body = []
        case .body(let buffer):
            body += buffer.readableBytesView
        case .end:
            guard let head, body.count >= 12 else { return }
            seen.withLockedValue {
                $0.append(
                    Seen(
                        method: head.method.rawValue, uri: head.uri,
                        contentType: head.headers.first(name: "content-type"),
                        id: UInt16(body[0]) << 8 | UInt16(body[1])))
            }
            let reply = status == .ok ? answer(body) : []
            var headers = HTTPHeaders()
            headers.add(name: "content-type", value: "application/dns-message")
            headers.add(name: "content-length", value: String(reply.count))
            context.write(
                wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))),
                promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: reply)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private func startDoH(
    group: any EventLoopGroup, http2: Bool, status: HTTPResponseStatus = .ok,
    seen: NIOLockedValueBox<[DoHServerHandler.Seen]>
) async throws -> (LoopbackTCPServer, TestCertificates) {
    let (context, certificates) = try serverContext(alpn: http2 ? ["h2"] : ["http/1.1"])
    let server = try await LoopbackTCPServer.start(group: group) { channel in
        channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
            if http2 {
                _ = try channel.pipeline.syncOperations.configureHTTP2Pipeline(
                    mode: .server, connectionConfiguration: .init(), streamConfiguration: .init()
                ) { stream in
                    stream.eventLoop.makeCompletedFuture {
                        try stream.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTP1ServerCodec())
                        try stream.pipeline.syncOperations.addHandler(DoHServerHandler(status: status, seen: seen))
                    }
                }
            } else {
                try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                try channel.pipeline.syncOperations.addHandler(DoHServerHandler(status: status, seen: seen))
            }
        }
    }
    return (server, certificates)
}

@Suite("DNS over TLS / HTTPS (07 §4)")
struct EncryptedDNSTests {
    @Test("DoT pipelines queries on one connection, maps reordered answers back and reconnects after a close")
    func dot() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let (context, certificates) = try serverContext(alpn: [])
        let ids = NIOLockedValueBox<[UInt16]>([])
        let connections = NIOLockedValueBox(0)
        let server = try await LoopbackTCPServer.start(group: group) { channel in
            connections.withLockedValue { $0 += 1 }
            return channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                try channel.pipeline.syncOperations.addHandler(DoTServerHandler(batch: 2, closeAfter: 2, ids: ids))
            }
        }
        let loop = group.next()
        let client = DNSOverTLSClient(
            endpoint: EncryptedDNSEndpoint(
                host: "dns.example.com", port: UInt16(server.port), tls: clientTLS(certificates),
                resolver: LoopbackResolver()),
            eventLoop: loop)
        // 两个查询使用相同的调用方 ID：线上的 ID 被重新分配，应答仍各自对应。
        async let first = client.query(query("a.example.com", id: 7)).get()
        async let second = client.query(query("bbbb.example.com", id: 7)).get()
        let (a, b) = try await (first, second)
        #expect(Array(a[0..<2]) == [0, 7] && Array(b[0..<2]) == [0, 7])
        #expect(lastOctet(a) == 13 && lastOctet(b) == 16)
        #expect(Set(ids.withLockedValue { $0 }).count == 2)
        #expect(connections.withLockedValue { $0 } == 1)
        // 服务端在两个应答后关闭：下一批查询重新连接。
        #expect(await Poll.until { connections.withLockedValue { $0 } == 1 })
        async let third = client.query(query("cc.example.com", id: 1)).get()
        async let fourth = client.query(query("ddd.example.com", id: 2)).get()
        let (c, d) = try await (third, fourth)
        #expect(lastOctet(c) == 14 && lastOctet(d) == 15)
        #expect(connections.withLockedValue { $0 } == 2)
        client.reset()
        try await server.close()
        try await group.shutdownGracefully()
    }

    @Test(
        "DoH uses HTTP/2 when offered, falls back to HTTP/1.1, sends ID 0 and restores the caller's ID",
        arguments: [true, false])
    func doh(http2: Bool) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let seen = NIOLockedValueBox<[DoHServerHandler.Seen]>([])
        let (server, certificates) = try await startDoH(group: group, http2: http2, seen: seen)
        let client = try #require(
            DNSOverHTTPSClient(
                url: "https://dns.example.com:\(server.port)/dns-query?ct", resolver: LoopbackResolver(),
                tls: clientTLS(certificates), eventLoop: group.next()))
        let replies = try await withThrowingTaskGroup(of: [UInt8].self) { tasks in
            for (index, name) in ["a.example.com", "bb.example.com", "ccc.example.com"].enumerated() {
                tasks.addTask { try await client.query(query(name, id: UInt16(100 + index))).get() }
            }
            return try await tasks.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(replies.compactMap(lastOctet)) == [13, 14, 15])
        #expect(Set(replies.map { UInt16($0[0]) << 8 | UInt16($0[1]) }) == [100, 101, 102])
        let requests = seen.withLockedValue { $0 }
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.method == "POST" && $0.uri == "/dns-query?ct" && $0.id == 0 })
        #expect(requests.allSatisfy { $0.contentType == "application/dns-message" })
        client.reset()
        try await server.close()
        try await group.shutdownGracefully()
    }

    @Test("A non-200 DoH answer and an untrusted certificate fail the query")
    func failures() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let seen = NIOLockedValueBox<[DoHServerHandler.Seen]>([])
        let (server, certificates) = try await startDoH(
            group: group, http2: true, status: .internalServerError, seen: seen)
        let failing = try #require(
            DNSOverHTTPSClient(
                url: "https://dns.example.com:\(server.port)/dns-query", resolver: LoopbackResolver(),
                tls: clientTLS(certificates), eventLoop: group.next()))
        await #expect(throws: NetworkError.self) { _ = try await failing.query(query("a.example.com", id: 1)).get() }
        let untrusted = try #require(
            DNSOverHTTPSClient(
                url: "https://dns.example.com:\(server.port)/dns-query", resolver: LoopbackResolver(),
                eventLoop: group.next()))
        await #expect(throws: TLSError.self) { _ = try await untrusted.query(query("a.example.com", id: 1)).get() }
        #expect(
            DNSOverHTTPSClient(
                url: "http://dns.example.com/dns-query", resolver: LoopbackResolver(), eventLoop: group.next()) == nil)
        try await server.close()
        try await group.shutdownGracefully()
    }
}
