import Crypto
import Foundation

/// 代理协议使用的 AEAD（swift-crypto）：nonce 12 字节，标签 16 字节（docs/06 §8.4）。
public enum AEADAlgorithm: Sendable, Hashable {
    case aes128GCM
    case aes256GCM
    case chacha20Poly1305

    public static let nonceLength = 12
    public static let tagLength = 16

    public var keyLength: Int {
        switch self {
        case .aes128GCM: return 16
        case .aes256GCM, .chacha20Poly1305: return 32
        }
    }

    /// 加密，返回 密文 ‖ 标签。
    func seal(_ plaintext: some DataProtocol, key: SymmetricKey, nonce: [UInt8]) throws -> [UInt8] {
        switch self {
        case .aes128GCM, .aes256GCM:
            let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: nonce))
            return Array(box.ciphertext) + Array(box.tag)
        case .chacha20Poly1305:
            let box = try ChaChaPoly.seal(plaintext, using: key, nonce: ChaChaPoly.Nonce(data: nonce))
            return Array(box.ciphertext) + Array(box.tag)
        }
    }

    /// 解密 密文 ‖ 标签；认证失败时抛出。
    func open(_ sealed: [UInt8], key: SymmetricKey, nonce: [UInt8]) throws -> [UInt8] {
        guard sealed.count >= Self.tagLength else { throw CryptoKitError.incorrectParameterSize }
        let split = sealed.count - Self.tagLength
        let ciphertext = sealed[..<split]
        let tag = sealed[split...]
        switch self {
        case .aes128GCM, .aes256GCM:
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            return Array(try AES.GCM.open(box, using: key))
        case .chacha20Poly1305:
            let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            return Array(try ChaChaPoly.open(box, using: key))
        }
    }
}

/// 小端递增的 12 字节 nonce 计数器（Shadowsocks AEAD、VMess 等）。
struct AEADNonceCounter {
    private(set) var bytes = [UInt8](repeating: 0, count: AEADAlgorithm.nonceLength)

    /// 返回当前值并加一。
    mutating func next() -> [UInt8] {
        let current = bytes
        for index in bytes.indices {
            bytes[index] &+= 1
            if bytes[index] != 0 { break }
        }
        return current
    }
}
