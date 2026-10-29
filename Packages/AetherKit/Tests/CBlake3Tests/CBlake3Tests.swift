import AetherTestSupport
import CBlake3
import Foundation
import Testing

/// BLAKE3 官方测试向量（Tests/Fixtures/vectors/blake3/test_vectors.json，来源见 Vendor/blake3/README.md）。
struct CBlake3VectorTests {
    struct Vectors: Decodable {
        let key: String
        let contextString: String
        let cases: [Case]

        enum CodingKeys: String, CodingKey {
            case key
            case contextString = "context_string"
            case cases
        }
    }

    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let inputLen: Int
        let hash: String
        let keyedHash: String
        let deriveKey: String

        enum CodingKeys: String, CodingKey {
            case inputLen = "input_len"
            case hash
            case keyedHash = "keyed_hash"
            case deriveKey = "derive_key"
        }

        var testDescription: String { "input_len=\(inputLen)" }

        /// 向量约定的输入：第 i 个字节为 i % 251。
        var input: [UInt8] { (0..<inputLen).map { UInt8($0 % 251) } }
    }

    static let vectors: Vectors = {
        do {
            return try JSONDecoder().decode(Vectors.self, from: Fixtures.data("vectors/blake3/test_vectors.json"))
        } catch {
            return Vectors(key: "", contextString: "", cases: [])
        }
    }()

    @Test func vectorsLoaded() {
        #expect(Self.vectors.cases.count == 35)
        #expect(Self.vectors.key.utf8.count == Int(BLAKE3_KEY_LEN))
    }

    @Test(arguments: vectors.cases)
    func hash(_ testCase: Case) throws {
        var hasher = blake3_hasher()
        blake3_hasher_init(&hasher)
        #expect(output(&hasher, input: testCase.input, expected: testCase.hash) == testCase.hash)
    }

    @Test(arguments: vectors.cases)
    func keyedHash(_ testCase: Case) throws {
        var hasher = blake3_hasher()
        let key = Array(Self.vectors.key.utf8)
        key.withUnsafeBufferPointer { blake3_hasher_init_keyed(&hasher, $0.baseAddress) }
        #expect(output(&hasher, input: testCase.input, expected: testCase.keyedHash) == testCase.keyedHash)
    }

    @Test(arguments: vectors.cases)
    func deriveKey(_ testCase: Case) throws {
        var hasher = blake3_hasher()
        blake3_hasher_init_derive_key(&hasher, Self.vectors.contextString)
        #expect(output(&hasher, input: testCase.input, expected: testCase.deriveKey) == testCase.deriveKey)
    }

    /// 一次性写入输入，再按期望值的长度取扩展输出；同时校验分块写入得到相同结果。
    private func output(_ hasher: inout blake3_hasher, input: [UInt8], expected: String) -> String {
        var chunked = hasher
        let length = expected.utf8.count / 2
        var out = [UInt8](repeating: 0, count: length)
        input.withUnsafeBufferPointer { blake3_hasher_update(&hasher, $0.baseAddress, $0.count) }
        blake3_hasher_finalize(&hasher, &out, length)

        var chunkedOut = [UInt8](repeating: 0, count: length)
        for start in stride(from: 0, to: input.count, by: 1000) {
            let slice = Array(input[start..<min(start + 1000, input.count)])
            slice.withUnsafeBufferPointer { blake3_hasher_update(&chunked, $0.baseAddress, $0.count) }
        }
        blake3_hasher_finalize(&chunked, &chunkedOut, length)
        #expect(chunkedOut == out)
        return Hex.encode(out)
    }
}
