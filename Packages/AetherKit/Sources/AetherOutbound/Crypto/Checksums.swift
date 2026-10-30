/// CRC-32（IEEE 802.3，反射多项式 0xEDB88320）：VMess AuthID 的校验（docs/06 §8.4）。
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

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
