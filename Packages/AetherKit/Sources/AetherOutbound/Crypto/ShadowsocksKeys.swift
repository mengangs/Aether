import Crypto
import Foundation

/// Shadowsocks AEAD 的加密方式与密钥派生（shadowsocks.org AEAD 规范，docs/06 §8.4）。
public enum ShadowsocksAEADMethod: String, Sendable, Hashable, CaseIterable {
    case aes128GCM = "aes-128-gcm"
    case aes256GCM = "aes-256-gcm"
    case chacha20IETFPoly1305 = "chacha20-ietf-poly1305"

    var algorithm: AEADAlgorithm {
        switch self {
        case .aes128GCM: return .aes128GCM
        case .aes256GCM: return .aes256GCM
        case .chacha20IETFPoly1305: return .chacha20Poly1305
        }
    }

    public var keyLength: Int { algorithm.keyLength }
    /// salt 与密钥等长。
    public var saltLength: Int { algorithm.keyLength }
}

enum ShadowsocksKDF {
    /// OpenSSL `EVP_BytesToKey`（MD5、无 salt、迭代 1 次）：`D_i = MD5(D_{i-1} ‖ password)`，拼接后取前 `length` 字节。
    static func bytesToKey(password: [UInt8], length: Int) -> [UInt8] {
        var result: [UInt8] = []
        var previous: [UInt8] = []
        while result.count < length {
            previous = Array(Insecure.MD5.hash(data: previous + password))
            result += previous
        }
        return Array(result.prefix(length))
    }

    /// 会话子密钥 `HKDF-SHA1(masterKey, salt, "ss-subkey")`。
    static func subkey(masterKey: [UInt8], salt: [UInt8], length: Int) -> SymmetricKey {
        HKDF<Insecure.SHA1>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey), salt: salt, info: Array("ss-subkey".utf8),
            outputByteCount: length)
    }
}
