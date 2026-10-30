import AetherFoundation
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import AetherOutbound

/// VMess AEAD 的测试向量（Tests/Fixtures/vectors/vmess/aead.json，由同目录的 generate.py 用 Python
/// `cryptography` 独立生成）。
struct VMessVectors: Decodable {
    struct KDF: Decodable {
        let path1: String
        let path3: String
    }

    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let security: String
        let header: String
        let requestBody: String
        let response: String

        var testDescription: String { security }

        var vmessSecurity: VMessSecurity {
            switch security {
            case "chacha20-poly1305": return .chacha20Poly1305
            case "none": return .none
            default: return .aes128GCM
            }
        }
    }

    let uuid: String
    let time: Double
    let commandKey: String
    let kdf: KDF
    let cases: [Case]

    static let loaded: VMessVectors = {
        do {
            return try JSONDecoder().decode(VMessVectors.self, from: Fixtures.data("vectors/vmess/aead.json"))
        } catch {
            Issue.record("vectors: \(error)")
            return VMessVectors(uuid: "", time: 0, commandKey: "", kdf: KDF(path1: "", path3: ""), cases: [])
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

@Suite("VMess primitives (06 §8.4)")
struct VMessPrimitiveTests {
    @Test("AES-128 single block: FIPS-197 Appendix C.1")
    func aes() throws {
        let cipher = try #require(AESBlock(key: Array(0..<16)))
        let plain: [UInt8] = [
            0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff,
        ]
        #expect(cipher.encrypt(plain) == hex("69c4e0d86a7b0430d8cdb78070b4c55a"))
        #expect(AESBlock(key: [1, 2, 3]) == nil)
        #expect(cipher.encrypt([1]) == nil)
    }

    @Test("CRC-32 check value and FNV-1a 32 reference values")
    func checksums() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum([]) == 0)
        #expect(FNV1a32.hash([]) == 0x811C_9DC5)
        #expect(FNV1a32.hash(Array("a".utf8)) == 0xE40C_292C)
        #expect(FNV1a32.hash(Array("foobar".utf8)) == 0xBF9C_F968)
    }

    @Test("Nested HMAC KDF and command key match the vectors")
    func kdf() throws {
        let vectors = VMessVectors.loaded
        let connector = try #require(
            VMessConnector(
                name: "V", server: ProxyServer(host: "vmess.example.com", port: 443), uuid: vectors.uuid,
                security: .aes128GCM, udpEnabled: false))
        #expect(connector.commandKey == hex(vectors.commandKey))
        #expect(
            VMessKDF.derive(connector.commandKey, path: [Array("AES Auth ID Encryption".utf8)])
                == hex(vectors.kdf.path1))
        let longElement = [UInt8](repeating: 0x63, count: 70)
        #expect(
            VMessKDF.derive(Array("key".utf8), path: [Array("a".utf8), Array("bb".utf8), longElement])
                == hex(vectors.kdf.path3))
    }
}

@Suite("VMess AEAD (06 §8.4)")
struct VMessTests {
    private func connector(_ vector: VMessVectors.Case, random: CountingRandom) throws -> VMessConnector {
        let vectors = VMessVectors.loaded
        let time = vectors.time
        let connector = VMessConnector(
            name: "V", server: ProxyServer(host: "vmess.example.com", port: 443), uuid: vectors.uuid,
            security: vector.vmessSecurity, udpEnabled: false, clock: { Date(timeIntervalSince1970: time) },
            random: { random.take($0) })
        return try #require(connector)
    }

    @Test(
        "Request header, request chunks and response decoding match the vectors", arguments: VMessVectors.loaded.cases)
    func vectors(_ vector: VMessVectors.Case) throws {
        let random = CountingRandom()
        let connector = try connector(vector, random: random)
        let session = connector.makeSession()
        let header = try connector.sealedHeader(
            session: session, command: VMessConnector.commandTCP,
            destination: Destination(host: "www.example.com", port: 443)!)
        #expect(header == hex(vector.header))

        // 管线：加入时发出请求头；写入 "hello" 后半关闭，发出数据块与结束块；收到响应后交出 "world" 与 EOF。
        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "192.0.2.1", port: 443)).wait()
        try channel.pipeline.syncOperations.addHandler(
            VMessStreamHandler(session: session, header: header, packetMode: false))
        let events = NIOLockedValueBox<[String]>([])
        try channel.pipeline.syncOperations.addHandler(EventRecorder(events: events))
        #expect(try channel.readOutbound(as: ByteBuffer.self).map { Array($0.readableBytesView) } == header)
        try channel.writeOutbound(ByteBuffer(string: "hello"))
        channel.close(mode: .output, promise: nil)
        var body: [UInt8] = []
        while let buffer = try channel.readOutbound(as: ByteBuffer.self) {
            body += Array(buffer.readableBytesView)
        }
        #expect(body == hex(vector.requestBody))
        #expect(channel.isActive, "output close must not close the connection")

        let response = hex(vector.response)
        try channel.writeInbound(ByteBuffer(bytes: response[..<10]))
        try channel.writeInbound(ByteBuffer(bytes: response[10...]))
        #expect(events.withLockedValue { $0 } == ["data:world", "inputClosed"])
        _ = try? channel.finish()
    }

    @Test("A tampered response header closes with NET-032")
    func tamperedResponse() throws {
        let vector = try #require(VMessVectors.loaded.cases.first)
        let random = CountingRandom()
        let connector = try connector(vector, random: random)
        let session = connector.makeSession()
        let channel = EmbeddedChannel()
        try channel.pipeline.syncOperations.addHandler(
            VMessStreamHandler(session: session, header: [], packetMode: false))
        let events = NIOLockedValueBox<[String]>([])
        try channel.pipeline.syncOperations.addHandler(EventRecorder(events: events))
        var response = hex(vector.response)
        response[20] ^= 0x01
        _ = try? channel.writeInbound(ByteBuffer(bytes: response))
        #expect(events.withLockedValue { $0 } == ["error:NET-032"])
        #expect(!channel.isActive)
    }

    @Test("Chunk sealer and opener round-trip every security, packets keep their boundaries")
    func chunks() throws {
        for security in [VMessSecurity.aes128GCM, .chacha20Poly1305, .none] {
            let key = Array(0..<16).map(UInt8.init)
            let iv = Array(16..<32).map(UInt8.init)
            var sealer = VMessChunkSealer(security: security, key: key, iv: iv)
            var opener = VMessChunkOpener(security: security, key: key, iv: iv)
            var stream = ByteBuffer()
            for text in ["one", "two", ""] {
                try sealer.seal(Array(text.utf8), into: &stream)
            }
            var chunks: [String] = []
            while let chunk = try opener.next(&stream) {
                chunks.append(String(decoding: chunk, as: UTF8.self))
            }
            #expect(chunks == ["one", "two", ""], "\(security)")
        }
    }
}

private final class EventRecorder: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    let events: NIOLockedValueBox<[String]>

    init(events: NIOLockedValueBox<[String]>) {
        self.events = events
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let text = String(buffer: unwrapInboundIn(data))
        events.withLockedValue { $0.append("data:\(text)") }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            events.withLockedValue { $0.append("inputClosed") }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        if let error = error as? NetworkError {
            events.withLockedValue { $0.append("error:\(error.code.rawValue)") }
        }
    }
}
