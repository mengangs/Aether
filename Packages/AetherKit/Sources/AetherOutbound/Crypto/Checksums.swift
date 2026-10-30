// CRC-32 在 AetherFoundation（gzip 与 VMess 共用）。

/// FNV-1a 32 位：VMess 指令末尾的校验（docs/06 §8.4）。
enum FNV1a32 {
    static func hash(_ bytes: [UInt8]) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in bytes {
            hash = (hash ^ UInt32(byte)) &* 0x0100_0193
        }
        return hash
    }
}
