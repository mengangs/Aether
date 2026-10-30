import Crypto

/// VMess AEAD 的密钥派生（v2fly / Xray `vmess/aead/kdf.go`，docs/06 §8.4）：嵌套 HMAC。
/// 第 0 层是以 "VMess AEAD KDF" 为密钥的 HMAC-SHA256，之后每个路径元素以前一层的 HMAC 为"哈希函数"
/// 再套一层 HMAC，最后一层对 `key` 求值。块长度始终是 SHA-256 的 64 字节，输出 32 字节。
enum VMessKDF {
    typealias HashFunction = ([UInt8]) -> [UInt8]

    static func derive(_ key: [UInt8], path: [[UInt8]]) -> [UInt8] {
        var hash: HashFunction = { Array(SHA256.hash(data: $0)) }
        for element in [Array("VMess AEAD KDF".utf8)] + path {
            let parent = hash
            hash = { message in hmac(parent, key: element, message: message) }
        }
        return hash(key)
    }

    static func derive16(_ key: [UInt8], path: [[UInt8]]) -> [UInt8] {
        Array(derive(key, path: path).prefix(16))
    }

    /// RFC 2104 HMAC，`hash` 的块长度为 64 字节。
    static func hmac(_ hash: HashFunction, key: [UInt8], message: [UInt8]) -> [UInt8] {
        var block = key.count > 64 ? hash(key) : key
        block += [UInt8](repeating: 0, count: 64 - block.count)
        let inner = hash(block.map { $0 ^ 0x36 } + message)
        return hash(block.map { $0 ^ 0x5C } + inner)
    }
}
