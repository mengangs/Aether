import AetherFoundation
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import AetherOutbound

/// Shadowsocks 2022 的测试向量（Tests/Fixtures/vectors/shadowsocks2022/vectors.json，由同目录的 generate.py
/// 用 Python `blake3` 与 `cryptography` 独立生成）。
struct Shadowsocks2022Vectors: Decodable {
    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let method: String
        let psk: String
        let request: String
        let requestChunk: String
        let response: String
        let udpRequest: String?
        let udpResponse: String?

        var testDescription: String { method }
        var ssMethod: Shadowsocks2022Method { Shadowsocks2022Method(rawValue: method) ?? .blake3AES128GCM }
    }

    let time: Double
    let cases: [Case]

    static let loaded: Shadowsocks2022Vectors = {
        do {
            return try JSONDecoder().decode(
                Shadowsocks2022Vectors.self, from: Fixtures.data("vectors/shadowsocks2022/vectors.json"))
        } catch {
            Issue.record("vectors: \(error)")
            return Shadowsocks2022Vectors(time: 0, cases: [])
        }
    }()
}

private func hex(_ text: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var index = text.startIndex
    while index < text.endIndex {
        let next = text.index(index, offsetBy: 2)
        bytes.append(UInt8(text[index..<next], radix: 16) ?? 0)
        index = next
    }
    return bytes
}

/// 与 generate.py 相同的随机字节流：第 k 个字节为 (0x10 + k) % 256。
private final class CountingRandom: Sendable {
    private let next = NIOLockedValueBox(0)

    func take(_ count: Int) -> [UInt8] {
        next.withLockedValue { start in
            defer { start += count }
            return (0..<count).map { UInt8((0x10 + start + $0) % 256) }
        }
    }
}

private final class Events: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    let log = NIOLockedValueBox<[String]>([])

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let text = String(buffer: unwrapInboundIn(data))
        log.withLockedValue { $0.append(text) }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if let error = error as? NetworkError {
            log.withLockedValue { $0.append("error:\(error.code.rawValue)") }
        }
    }
}

@Suite("Shadowsocks 2022 (06 §8.4)")
struct Shadowsocks2022Tests {
    private func connector(_ vector: Shadowsocks2022Vectors.Case, time: Double) throws -> Shadowsocks2022Connector {
        let random = CountingRandom()
        let password = Data(hex(vector.psk)).base64EncodedString()
        let connector = Shadowsocks2022Connector(
            name: "SS", server: ProxyServer(host: "ss.example.com", port: 8388), method: vector.ssMethod,
            password: password, obfs: nil, udpEnabled: true, clock: { Date(timeIntervalSince1970: time) },
            random: { random.take($0) })
        return try #require(connector)
    }

    @Test(
        "Request prefix and chunks match the vectors; responses decode and are verified",
        arguments: Shadowsocks2022Vectors.loaded.cases)
    func tcp(_ vector: Shadowsocks2022Vectors.Case) throws {
        let time = Shadowsocks2022Vectors.loaded.time
        let connector = try connector(vector, time: time)
        var prefix = try connector.requestPrefix(destination: Destination(host: "www.example.com", port: 443)!)
        #expect(prefix.bytes == hex(vector.request))
        var chunk = ByteBuffer()
        try prefix.sealer.sealChunk(Array("hello".utf8), into: &chunk)
        #expect(Array(chunk.readableBytesView) == hex(vector.requestChunk))

        func decode(_ bytes: [UInt8], clock: Double = time, salt: [UInt8]? = nil) -> [String] {
            let channel = EmbeddedChannel()
            let events = Events()
            let opener = Stream2022Opener(
                method: vector.ssMethod, psk: connector.psk, requestSalt: salt ?? prefix.salt,
                clock: { Date(timeIntervalSince1970: clock) })
            try? channel.pipeline.syncOperations.addHandler(
                Shadowsocks2022StreamHandler(prefix: [], sealer: prefix.sealer, opener: opener))
            try? channel.pipeline.syncOperations.addHandler(events)
            // 分两次到达，验证跨读取的解析。
            _ = try? channel.writeInbound(ByteBuffer(bytes: bytes[..<7]))
            _ = try? channel.writeInbound(ByteBuffer(bytes: bytes[7...]))
            return events.log.withLockedValue { $0 }
        }
        let response = hex(vector.response)
        // 一次读取中解出的数据合并交出。
        #expect(decode(response).joined() == "world!!")
        // 时间戳偏差超过 30 秒、请求 salt 不符、密文被篡改都以 NET-032 结束。
        #expect(decode(response, clock: time + 31) == ["error:NET-032"])
        #expect(decode(response, salt: [UInt8](repeating: 0, count: vector.ssMethod.keyLength)) == ["error:NET-032"])
        // 认证失败的那次读取中的数据不交出。
        var tampered = response
        tampered[tampered.count - 1] ^= 0x01
        #expect(decode(tampered) == ["error:NET-032"])
    }

    @Test(
        "UDP packets (AES variants) match the vectors; replies are verified",
        arguments: Shadowsocks2022Vectors.loaded.cases)
    func udp(_ vector: Shadowsocks2022Vectors.Case) throws {
        guard let request = vector.udpRequest, let response = vector.udpResponse else {
            #expect(!vector.ssMethod.supportsUDP)
            return
        }
        let time = Shadowsocks2022Vectors.loaded.time
        let random = CountingRandom()
        let make = { (clock: Double) in
            Shadowsocks2022UDPCodec(
                method: vector.ssMethod, psk: hex(vector.psk), sessionID: CountingRandom().take(8),
                clock: { Date(timeIntervalSince1970: clock) }, random: { random.take($0) })
        }
        let codec = try #require(make(time))
        let allocator = ByteBufferAllocator()
        let packet = try codec.seal(
            ByteBuffer(string: "query"), destination: .ip(IPAddress("192.0.2.53")!, port: 53), allocator: allocator)
        #expect(Array(packet.readableBytesView) == hex(request))
        let opened = try #require(codec.open(ByteBuffer(bytes: hex(response)), allocator: allocator))
        #expect(opened.source == .ip(IPAddress("198.51.100.7")!, port: 5353))
        #expect(String(buffer: opened.payload) == "answer")
        // 时间戳过旧或被篡改的回包丢弃。
        #expect(try #require(make(time + 60)).open(ByteBuffer(bytes: hex(response)), allocator: allocator) == nil)
        var tampered = hex(response)
        tampered[20] ^= 0x01
        #expect(codec.open(ByteBuffer(bytes: tampered), allocator: allocator) == nil)
    }

    @Test("PSK must be Base64 of the method's key length; multi-user iPSK form is rejected")
    func passwords() {
        let server = ProxyServer(host: "ss.example.com", port: 8388)
        let psk16 = Data(repeating: 1, count: 16).base64EncodedString()
        #expect(
            Shadowsocks2022Connector(
                name: "A", server: server, method: .blake3AES128GCM, password: psk16, udpEnabled: false) != nil)
        #expect(
            Shadowsocks2022Connector(
                name: "A", server: server, method: .blake3AES256GCM, password: psk16, udpEnabled: false) == nil)
        #expect(
            Shadowsocks2022Connector(
                name: "A", server: server, method: .blake3AES128GCM, password: "not base64", udpEnabled: false) == nil)
        #expect(
            Shadowsocks2022Connector(
                name: "A", server: server, method: .blake3AES128GCM, password: psk16 + ":" + psk16, udpEnabled: false)
                == nil)
        let chacha = Shadowsocks2022Connector(
            name: "C", server: server, method: .blake3ChaCha20Poly1305,
            password: Data(repeating: 1, count: 32).base64EncodedString(), udpEnabled: true)
        #expect(chacha?.capabilities.contains(.udp) == false)
    }
}

@Suite("simple-obfs tls and AES block (06 §8.4–§8.5)")
struct SimpleObfsTLSTests {
    @Test("AES-128 / AES-256 encrypt and decrypt: FIPS-197 Appendix C.1 and C.3")
    func aesVectors() throws {
        let plain = hex("00112233445566778899aabbccddeeff")
        let aes128 = try #require(AESBlock(key: Array(0..<16)))
        #expect(aes128.encrypt(plain) == hex("69c4e0d86a7b0430d8cdb78070b4c55a"))
        #expect(aes128.decrypt(hex("69c4e0d86a7b0430d8cdb78070b4c55a")) == plain)
        let aes256 = try #require(AESBlock(key: Array(0..<32)))
        #expect(aes256.encrypt(plain) == hex("8ea2b7ca516745bfeafc49904b496089"))
        #expect(aes256.decrypt(hex("8ea2b7ca516745bfeafc49904b496089")) == plain)
        #expect(AESBlock(key: Array(repeating: 0, count: 24)) == nil)
    }

    @Test("The ClientHello carries the data in the session ticket right after the fixed part, then SNI")
    func clientHello() {
        let ticket = Array("first bytes".utf8)
        var hello = SimpleObfsTLSHandler.clientHello(
            ticket: ticket, host: "cdn.example.com", random: [UInt8](repeating: 7, count: 32),
            sessionID: [UInt8](repeating: 9, count: 32))
        let bytes = hello.readBytes(length: hello.readableBytes) ?? []
        // obfs-server 的检查：16 03 01、握手类型 1、版本 03 03。
        #expect(Array(bytes[0..<3]) == [0x16, 0x03, 0x01] && bytes[5] == 0x01 && bytes[9] == 0x03 && bytes[10] == 0x03)
        #expect(Int(bytes[3]) << 8 | Int(bytes[4]) == bytes.count - 5)
        #expect(Int(bytes[7]) << 8 | Int(bytes[8]) == bytes.count - 9)
        // 固定部分 138 字节之后紧跟 session ticket 扩展（0x0023）与数据。
        #expect(Array(bytes[138..<142]) == [0x00, 0x23, 0x00, UInt8(ticket.count)])
        #expect(Array(bytes[142..<(142 + ticket.count)]) == ticket)
        let sni = 142 + ticket.count
        #expect(Array(bytes[sni..<(sni + 2)]) == [0x00, 0x00])
        #expect(String(decoding: bytes[(sni + 9)..<(sni + 9 + 15)], as: UTF8.self) == "cdn.example.com")
        #expect(Array(bytes.suffix(SimpleObfsTLSHandler.otherExtensions.count)) == SimpleObfsTLSHandler.otherExtensions)
    }

    @Test(
        "Responses: ServerHello and ChangeCipherSpec are skipped, data comes from the next handshake record and app data"
    )
    func response() throws {
        let channel = EmbeddedChannel()
        let events = Events()
        try channel.pipeline.syncOperations.addHandler(SimpleObfsTLSHandler(host: "cdn.example.com"))
        try channel.pipeline.syncOperations.addHandler(events)
        var stream: [UInt8] = [0x16, 0x03, 0x01, 0x00, 0x04, 2, 0, 0, 0]
        stream += [0x14, 0x03, 0x03, 0x00, 0x01, 0x01]
        stream += [0x16, 0x03, 0x03, 0x00, 0x03] + Array("one".utf8)
        stream += [0x17, 0x03, 0x03, 0x00, 0x03] + Array("two".utf8)
        try channel.writeInbound(ByteBuffer(bytes: stream[..<12]))
        try channel.writeInbound(ByteBuffer(bytes: stream[12...]))
        #expect(events.log.withLockedValue { $0 }.joined() == "onetwo")
        try channel.writeInbound(ByteBuffer(bytes: [0x42, 0x03, 0x03, 0x00, 0x01, 0x00]))
        #expect(events.log.withLockedValue { $0.last } == "error:NET-032")
        _ = try? channel.finish()

        // 写入：第一次是 ClientHello，之后为应用数据记录（每条 ≤ 16 KiB）。
        let writer = EmbeddedChannel()
        try writer.pipeline.syncOperations.addHandler(SimpleObfsTLSHandler(host: "cdn.example.com"))
        try writer.writeOutbound(ByteBuffer(string: "hello"))
        let hello = try #require(try writer.readOutbound(as: ByteBuffer.self))
        #expect(hello.getInteger(at: 0, as: UInt8.self) == 0x16)
        try writer.writeOutbound(ByteBuffer(bytes: [UInt8](repeating: 1, count: 20_000)))
        let records = try #require(try writer.readOutbound(as: ByteBuffer.self))
        #expect(Array(records.readableBytesView.prefix(5)) == [0x17, 0x03, 0x03, 0x40, 0x00])
        #expect(records.readableBytes == 5 + 16384 + 5 + (20_000 - 16384))
        _ = try? writer.finish()
    }
}
