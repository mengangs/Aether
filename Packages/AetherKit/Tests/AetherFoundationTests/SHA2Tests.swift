import AetherTestSupport
import Testing

@testable import AetherFoundation

/// SHA-256 向量：FIPS 180-4 示例与 Python `hashlib` 计算的各长度摘要（覆盖填充跨块的边界）。SHA-224 见 TrojanTests。
@Suite("SHA-256")
struct SHA2Tests {
    @Test(
        "FIPS 180-4 examples",
        arguments: [
            ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
            ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
            (
                "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
                "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            ),
        ])
    func examples(_ input: String, _ digest: String) {
        #expect(SHA2.sha256Hex(Array(input.utf8)) == digest)
        #expect(Hex.encode(SHA2.sha256(Array(input.utf8))) == digest)
    }

    @Test("Every length from 0 to 199 bytes and one million 'a'")
    func lengths() {
        // hashlib.sha256(b"".join(hashlib.sha256(bytes(i % 251 for i in range(n))).digest() for n in range(200)))
        let chained = (0..<200).flatMap { count in SHA2.sha256((0..<count).map { UInt8($0 % 251) }) }
        #expect(SHA2.sha256Hex(chained) == "ba7b0fcea7d10c06b855b43d2b4dce1e3e842fff6be0acefb0faf4f2dd05bb47")
        #expect(
            SHA2.sha256Hex([UInt8](repeating: 0x61, count: 1_000_000))
                == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }
}
