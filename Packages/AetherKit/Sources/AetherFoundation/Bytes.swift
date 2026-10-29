/// 字节工具（大端整数读写、十六进制）。用于协议编解码与测试。
public enum Bytes {
    /// 小写十六进制。
    public static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let table = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            out.append(table[Int(byte >> 4)])
            out.append(table[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 解析十六进制（大小写均可，允许 `:` 分隔，如证书指纹）。格式错误返回 nil。
    public static func fromHex(_ text: some StringProtocol) -> [UInt8]? {
        var bytes: [UInt8] = []
        var high: UInt8?
        for scalar in text.unicodeScalars where scalar != ":" {
            let nibble: UInt8
            switch scalar.value {
            case 0x30...0x39: nibble = UInt8(scalar.value - 0x30)
            case 0x41...0x46: nibble = UInt8(scalar.value - 0x41 + 10)
            case 0x61...0x66: nibble = UInt8(scalar.value - 0x61 + 10)
            default: return nil
            }
            if let h = high {
                bytes.append(h << 4 | nibble)
                high = nil
            } else {
                high = nibble
            }
        }
        return high == nil ? bytes : nil
    }

    /// 读取大端无符号整数；越界返回 nil。
    public static func readBigEndian<T: FixedWidthInteger & UnsignedInteger>(
        _ type: T.Type, from bytes: some Collection<UInt8>, at offset: Int
    ) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= bytes.count else { return nil }
        var value: T = 0
        var iterator = bytes.dropFirst(offset).prefix(size).makeIterator()
        while let byte = iterator.next() {
            value = value << 8 | T(byte)
        }
        return value
    }

    /// 追加大端无符号整数。
    public static func appendBigEndian<T: FixedWidthInteger & UnsignedInteger>(_ value: T, to bytes: inout [UInt8]) {
        let size = MemoryLayout<T>.size
        for shift in stride(from: (size - 1) * 8, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: value >> shift))
        }
    }
}
