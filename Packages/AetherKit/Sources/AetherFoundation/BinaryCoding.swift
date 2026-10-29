/// 小端二进制写入器（本地缓存文件格式用；网络协议用 SwiftNIO 的 ByteBuffer）。
public struct BinaryWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func write(_ value: UInt8) { bytes.append(value) }

    public mutating func write<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
    }

    public mutating func write(_ data: [UInt8]) {
        write(UInt32(data.count))
        bytes.append(contentsOf: data)
    }

    public mutating func write(_ string: String) {
        write(Array(string.utf8))
    }

    /// 原样追加（不写长度）。
    public mutating func append(raw: [UInt8]) { bytes.append(contentsOf: raw) }
}

/// 与 `BinaryWriter` 对应的读取器。所有读取都做越界检查，失败返回 nil，不会崩溃。
public struct BinaryReader {
    private let bytes: [UInt8]
    public private(set) var offset = 0

    public init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    public var isAtEnd: Bool { offset == bytes.count }
    public var remaining: Int { bytes.count - offset }

    public mutating func readByte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    public mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard remaining >= size else { return nil }
        var value: T = 0
        for index in 0..<size {
            value |= T(truncatingIfNeeded: bytes[offset + index]) << (8 * index)
        }
        offset += size
        return value
    }

    /// 读取带 UInt32 长度前缀的字节；长度超过 `limit` 或剩余数据时返回 nil。
    public mutating func readBytes(limit: Int = Int(UInt32.max)) -> [UInt8]? {
        guard let length = read(UInt32.self), Int(length) <= limit, Int(length) <= remaining else { return nil }
        defer { offset += Int(length) }
        return Array(bytes[offset..<(offset + Int(length))])
    }

    public mutating func readString(limit: Int = 1 << 20) -> String? {
        readBytes(limit: limit).map { String(decoding: $0, as: UTF8.self) }
    }

    /// 读取固定长度的原始字节。
    public mutating func readRaw(count: Int) -> [UInt8]? {
        guard count >= 0, remaining >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }
}
