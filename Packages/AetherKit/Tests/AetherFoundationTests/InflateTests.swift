import AetherTestSupport
import Foundation
import Testing

@testable import AetherFoundation

/// gzip 解压（Tests/Fixtures/compression/*.gz，由同目录的 generate.py 用 Python zlib 生成）。
@Suite("Inflate (RFC 1951 / 1952)")
struct InflateTests {
    static let text = Array((0..<2000).map { "DOMAIN-SUFFIX,host\($0).example.com\n" }.joined().utf8)

    private func fixture(_ name: String) throws -> [UInt8] {
        Array(try Fixtures.data("compression/\(name).gz"))
    }

    @Test(
        "Stored, fixed-Huffman, dynamic-Huffman and multi-member streams decode to the original",
        arguments: [
            "stored", "fixed", "dynamic", "multi",
        ])
    func decodes(_ name: String) throws {
        let data = try fixture(name)
        #expect(Inflate.isGzip(data))
        #expect(try Inflate.gunzip(data, limit: 1 << 20) == Self.text)
    }

    @Test("Empty member and a header with a file name")
    func headers() throws {
        #expect(try Inflate.gunzip(try fixture("empty"), limit: 16).isEmpty)
        #expect(try Inflate.gunzip(try fixture("named"), limit: 1024) == Array(Self.text.prefix(500)))
    }

    @Test("The output limit, truncation, corruption and bad checksums fail without crashing")
    func failures() throws {
        let data = try fixture("dynamic")
        #expect(throws: Inflate.Failure.tooLarge(limit: 1000)) { try Inflate.gunzip(data, limit: 1000) }
        #expect(throws: Inflate.Failure.self) { try Inflate.gunzip(Array(data.prefix(data.count / 2)), limit: 1 << 20) }
        var badCRC = data
        badCRC[badCRC.count - 6] ^= 0xFF
        #expect(throws: Inflate.Failure.checksumMismatch) { try Inflate.gunzip(badCRC, limit: 1 << 20) }
        #expect(throws: Inflate.Failure.invalidHeader) {
            try Inflate.gunzip([0x1F, 0x8B, 7] + data.dropFirst(3), limit: 1 << 20)
        }
        // 随机破坏正文：要么失败，要么（极少数情况下）解出不同内容，但都不能崩溃。
        var generator = SplitMix64(seed: 42)
        for _ in 0..<200 {
            var corrupted = data
            let index = 10 + Int(generator.next() % UInt64(data.count - 18))
            corrupted[index] ^= UInt8(truncatingIfNeeded: generator.next() | 1)
            _ = try? Inflate.gunzip(corrupted, limit: 1 << 20)
        }
        #expect(!Inflate.isGzip(Array("plain".utf8)))
    }

    @Test("Raw DEFLATE: a stored block with a bad length complement is rejected")
    func storedLength() throws {
        // BFINAL=1, BTYPE=00；LEN=5，NLEN 不是其反码。
        #expect(throws: Inflate.Failure.invalidStoredLength) {
            try Inflate.inflate([0x01, 0x05, 0x00, 0x00, 0x00] + Array("hello".utf8), limit: 64)
        }
        #expect(
            try Inflate.inflate([0x01, 0x05, 0x00, 0xFA, 0xFF] + Array("hello".utf8), limit: 64) == Array("hello".utf8))
        #expect(throws: Inflate.Failure.invalidBlockType) { try Inflate.inflate([0x07], limit: 64) }
    }
}
