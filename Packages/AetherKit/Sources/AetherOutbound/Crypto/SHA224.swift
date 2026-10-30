import AetherFoundation

/// SHA-224（FIPS 180-4 §6.3）：swift-crypto 不提供，Trojan 的密码摘要需要（docs/06 §8.4）。实现在 `AetherFoundation.SHA2`。
enum SHA224 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        SHA2.sha224(message)
    }
}
