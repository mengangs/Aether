import AetherDNS
import AetherFoundation
import AetherProfile
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL
import Testing

@testable import AetherEngine

/// 普通 DNS 上游的替身：只回答 dns.example.com → 127.0.0.1（DoT 服务器的域名自举解析）。
private final class BootstrapUpstream: DNSUpstream, @unchecked Sendable {
    let name = "192.0.2.53:53"
    let isSystem = false
    let queries = NIOLockedValueBox<[String]>([])

    func send(_ query: [UInt8], on eventLoop: any EventLoop) -> EventLoopFuture<[UInt8]> {
        guard let message = try? DNSMessage.decode(query), let question = message.questions.first else {
            return eventLoop.makeFailedFuture(DNSError(.dnsMalformedResponse, "bad query"))
        }
        let name = question.name.description.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        queries.withLockedValue { $0.append(name) }
        let answers =
            name == "dns.example.com" && question.type == .a
            ? [DNSResourceRecord(name: question.name, type: .a, ttl: 60, data: .a(IPv4Address(127, 0, 0, 1)))] : []
        return eventLoop.makeSucceededFuture(DNSMessage.response(to: message, answers: answers).encode())
    }
}

/// DoT 服务端：回答任何 A 查询为 192.0.2.77。
private final class DoTAnswerer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var buffer = ByteBuffer()

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self),
            buffer.readableBytes >= 2 + Int(length)
        {
            buffer.moveReaderIndex(forwardBy: 2)
            guard let bytes = buffer.readBytes(length: Int(length)), let query = try? DNSMessage.decode(bytes),
                let question = query.questions.first
            else { continue }
            let record = DNSResourceRecord(name: question.name, type: .a, ttl: 60, data: .a(IPv4Address(192, 0, 2, 77)))
            let encoded = DNSMessage.response(to: query, answers: question.type == .a ? [record] : []).encode()
            var out = context.channel.allocator.buffer(capacity: encoded.count + 2)
            out.writeInteger(UInt16(encoded.count))
            out.writeBytes(encoded)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
        buffer.discardReadBytes()
    }
}

@Suite("Encrypted DNS in the engine (07 §4)")
struct EncryptedDNSEngineTests {
    @Test(
        "encrypted-dns-server uses DoT; the server name is bootstrapped through dns-server; [Host] server: picks it per domain"
    )
    func encryptedUpstreams() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let certificates = try TestCertificates.make(dnsNames: ["dns.example.com"])
        var tls = TLSConfiguration.makeServerConfiguration(
            certificateChain: [.certificate(try NIOSSLCertificate(bytes: certificates.leafDER, format: .der))],
            privateKey: .privateKey(try NIOSSLPrivateKey(bytes: Array(certificates.leafKeyPEM.utf8), format: .pem)))
        tls.shutdownTimeout = .milliseconds(50)
        let context = try NIOSSLContext(configuration: tls)
        let server = try await LoopbackTCPServer.start(group: group) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: context))
                try channel.pipeline.syncOperations.addHandler(DoTAnswerer())
            }
        }
        let text = """
            [General]
            dns-server = 192.0.2.53
            encrypted-dns-server = tls://dns.example.com:\(server.port)

            [Host]
            *.corp.example.org = server:tls://dns.example.com:\(server.port)

            [Rule]
            FINAL,DIRECT
            """
        let configuration = RuntimeConfiguration.compile(ProfileResolver.resolve(profileText: text, fileName: "t.conf"))
        let bootstrap = BootstrapUpstream()
        var options = Engine.Options()
        options.socksCredentials = nil
        options.httpProxy = nil
        options.periodicTests = false
        options.encryptedDNSTrustRoots = [certificates.caPEM]
        options.dnsUpstreams = { spec in
            if case .udp = spec { return bootstrap }
            return nil
        }
        let engine = try await Engine.start(configuration: configuration, options: options)
        let dns = engine.dns
        let direct = try await engine.eventLoop.flatSubmit {
            dns.resolve("www.example.com", type: .a, purpose: .direct)
        }
        .get()
        #expect(direct == [IPAddress("192.0.2.77")!])
        let perDomain = try await engine.eventLoop.flatSubmit {
            dns.resolve("app.corp.example.org", type: .a, purpose: .server)
        }.get()
        #expect(perDomain == [IPAddress("192.0.2.77")!])
        // 普通上游只收到 DoT 服务器的自举查询。
        #expect(bootstrap.queries.withLockedValue { $0 }.allSatisfy { $0 == "dns.example.com" })
        try await engine.eventLoop.submit { dns.resetUpstreams() }.get()
        await engine.stop()
        try await server.close()
        try await group.shutdownGracefully()
    }

    @Test("DoT host and port parsing")
    func hostPort() {
        #expect(
            EncryptedDNSUpstream.hostPort("tls://dns.example.com", prefix: "tls://", defaultPort: 853)! == (
                "dns.example.com", 853
            ))
        #expect(
            EncryptedDNSUpstream.hostPort("tls://dns.example.com:8853", prefix: "tls://", defaultPort: 853)! == (
                "dns.example.com", 8853
            ))
        #expect(
            EncryptedDNSUpstream.hostPort("tls://[2001:db8::53]:853", prefix: "tls://", defaultPort: 853)! == (
                "2001:db8::53", 853
            ))
        #expect(EncryptedDNSUpstream.hostPort("tls://dns.example.com:x", prefix: "tls://", defaultPort: 853) == nil)
        #expect(EncryptedDNSUpstream.hostPort("https://dns.example.com", prefix: "tls://", defaultPort: 853) == nil)
    }
}
