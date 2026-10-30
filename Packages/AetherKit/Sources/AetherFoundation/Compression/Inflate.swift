/// DEFLATE 解压（RFC 1951）与 gzip 容器（RFC 1952），纯 Swift 实现（外部资源的 `.gz`，docs/11 §5.3）。
///
/// 按规范逐位解码（规范 Huffman 码表，与 zlib 的参考解码器 puff 的思路一致），不追求速度；输出超过 `limit`
/// 字节时立即失败（防止压缩炸弹），任何越界、无效码或校验不符都抛出 `Inflate.Failure`，不会崩溃。
public enum Inflate {
    public enum Failure: Error, Equatable, Sendable {
        case truncated
        case invalidBlockType
        case invalidStoredLength
        case invalidCode
        case invalidDistance
        case tooLarge(limit: Int)
        case invalidHeader
        case checksumMismatch
    }

    /// gzip 魔数 `1f 8b`。
    public static func isGzip(_ data: [UInt8]) -> Bool {
        data.count >= 2 && data[0] == 0x1F && data[1] == 0x8B
    }

    /// 解压 gzip（支持多个成员串接）；校验每个成员的 CRC-32 与长度。
    public static func gunzip(_ data: [UInt8], limit: Int) throws(Failure) -> [UInt8] {
        var output: [UInt8] = []
        var offset = 0
        repeat {
            let start = output.count
            offset = try member(data, at: offset, into: &output, limit: limit)
            let crc = CRC32.checksum(output[start...])
            guard offset + 8 <= data.count else { throw .truncated }
            let expectedCRC = littleEndian32(data, offset)
            let expectedSize = littleEndian32(data, offset + 4)
            guard crc == expectedCRC, UInt32(truncatingIfNeeded: output.count - start) == expectedSize else {
                throw .checksumMismatch
            }
            offset += 8
        } while offset < data.count && isGzip(Array(data[offset...].prefix(2)))
        return output
    }

    /// 解压原始 DEFLATE 流。
    public static func inflate(_ data: [UInt8], limit: Int) throws(Failure) -> [UInt8] {
        var output: [UInt8] = []
        var reader = BitReader(data: data, position: 0)
        try decode(&reader, into: &output, limit: limit)
        return output
    }

    private static func littleEndian32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16
            | UInt32(data[offset + 3]) << 24
    }

    /// 解析一个 gzip 成员的头并解压正文，返回尾部（CRC-32、ISIZE）的位置。
    private static func member(_ data: [UInt8], at start: Int, into output: inout [UInt8], limit: Int) throws(Failure)
        -> Int
    {
        guard data.count >= start + 10 else { throw .truncated }
        guard data[start] == 0x1F, data[start + 1] == 0x8B, data[start + 2] == 8 else { throw .invalidHeader }
        let flags = data[start + 3]
        guard flags & 0xE0 == 0 else { throw .invalidHeader }
        var offset = start + 10
        if flags & 0x04 != 0 {  // FEXTRA
            guard offset + 2 <= data.count else { throw .truncated }
            offset += 2 + (Int(data[offset]) | Int(data[offset + 1]) << 8)
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // FNAME、FCOMMENT：以 0 结尾
            while true {
                guard offset < data.count else { throw .truncated }
                offset += 1
                if data[offset - 1] == 0 { break }
            }
        }
        if flags & 0x02 != 0 {  // FHCRC
            offset += 2
        }
        guard offset <= data.count else { throw .truncated }
        var reader = BitReader(data: data, position: offset)
        try decode(&reader, into: &output, limit: limit)
        return reader.alignedPosition
    }

    // MARK: - DEFLATE

    private struct BitReader {
        let data: [UInt8]
        var position: Int
        var bitBuffer: UInt32 = 0
        var bitCount = 0

        mutating func bits(_ count: Int) throws(Failure) -> Int {
            var value = bitBuffer
            while bitCount < count {
                guard position < data.count else { throw .truncated }
                value |= UInt32(data[position]) << UInt32(bitCount)
                position += 1
                bitCount += 8
            }
            bitBuffer = value >> UInt32(count)
            bitCount -= count
            return Int(value & ((1 << UInt32(count)) - 1))
        }

        /// 丢弃不足一字节的位，返回下一个整字节的位置。
        var alignedPosition: Int { position - bitCount / 8 }

        mutating func align() {
            bitBuffer = 0
            bitCount = 0
        }
    }

    /// 规范 Huffman 码表：`counts[len]` 为长度为 len 的码的个数，`symbols` 按码排序。
    private struct Huffman {
        var counts = [Int](repeating: 0, count: 16)
        var symbols: [Int]

        /// 由码长构造；码长过度占用（不可能的前缀码）时失败。不完整的码表允许（单个距离码等情况）。
        init(lengths: ArraySlice<Int>) throws(Failure) {
            symbols = [Int](repeating: 0, count: lengths.count)
            for length in lengths {
                counts[length] += 1
            }
            var left = 1
            for length in 1..<16 {
                left <<= 1
                left -= counts[length]
                guard left >= 0 else { throw .invalidCode }
            }
            var offsets = [Int](repeating: 0, count: 16)
            for length in 1..<15 {
                offsets[length + 1] = offsets[length] + counts[length]
            }
            for (symbol, length) in lengths.enumerated() where length != 0 {
                symbols[offsets[length]] = symbol
                offsets[length] += 1
            }
        }

        func decode(_ reader: inout BitReader) throws(Failure) -> Int {
            var code = 0
            var first = 0
            var index = 0
            for length in 1..<16 {
                code |= try reader.bits(1)
                let count = counts[length]
                if code - count < first {
                    return symbols[index + (code - first)]
                }
                index += count
                first += count
                first <<= 1
                code <<= 1
            }
            throw .invalidCode
        }
    }

    private static let lengthBase = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227,
        258,
    ]
    private static let lengthExtra = [
        0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0,
    ]
    private static let distanceBase = [
        1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097,
        6145, 8193, 12289, 16385, 24577,
    ]
    private static let distanceExtra = [
        0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13,
    ]

    private static let fixedTables: (Huffman, Huffman)? = {
        var lengths = [Int](repeating: 8, count: 288)
        for symbol in 144..<256 { lengths[symbol] = 9 }
        for symbol in 256..<280 { lengths[symbol] = 7 }
        guard let literals = try? Huffman(lengths: lengths[...]),
            let distances = try? Huffman(lengths: [Int](repeating: 5, count: 30)[...])
        else { return nil }
        return (literals, distances)
    }()

    private static func decode(_ reader: inout BitReader, into output: inout [UInt8], limit: Int) throws(Failure) {
        var last = false
        repeat {
            last = try reader.bits(1) == 1
            switch try reader.bits(2) {
            case 0:
                try stored(&reader, into: &output, limit: limit)
            case 1:
                guard let (literals, distances) = fixedTables else { throw .invalidCode }
                try codes(&reader, literals: literals, distances: distances, into: &output, limit: limit)
            case 2:
                let (literals, distances) = try dynamicTables(&reader)
                try codes(&reader, literals: literals, distances: distances, into: &output, limit: limit)
            default:
                throw .invalidBlockType
            }
        } while !last
    }

    private static func stored(_ reader: inout BitReader, into output: inout [UInt8], limit: Int) throws(Failure) {
        reader.position = reader.alignedPosition
        reader.align()
        guard reader.position + 4 <= reader.data.count else { throw .truncated }
        let data = reader.data
        let start = reader.position
        let length = Int(data[start]) | Int(data[start + 1]) << 8
        let complement = Int(data[start + 2]) | Int(data[start + 3]) << 8
        guard length == ~complement & 0xFFFF else { throw .invalidStoredLength }
        guard start + 4 + length <= data.count else { throw .truncated }
        guard output.count + length <= limit else { throw .tooLarge(limit: limit) }
        output.append(contentsOf: data[(start + 4)..<(start + 4 + length)])
        reader.position = start + 4 + length
    }

    private static func dynamicTables(_ reader: inout BitReader) throws(Failure) -> (Huffman, Huffman) {
        let literalCount = try reader.bits(5) + 257
        let distanceCount = try reader.bits(5) + 1
        let codeCount = try reader.bits(4) + 4
        guard literalCount <= 286, distanceCount <= 30 else { throw .invalidCode }
        let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var codeLengths = [Int](repeating: 0, count: 19)
        for index in 0..<codeCount {
            codeLengths[order[index]] = try reader.bits(3)
        }
        let lengthCode = try Huffman(lengths: codeLengths[...])
        var lengths: [Int] = []
        lengths.reserveCapacity(literalCount + distanceCount)
        while lengths.count < literalCount + distanceCount {
            let symbol = try lengthCode.decode(&reader)
            switch symbol {
            case 0..<16:
                lengths.append(symbol)
            case 16:
                guard let previous = lengths.last else { throw .invalidCode }
                lengths += [Int](repeating: previous, count: 3 + (try reader.bits(2)))
            case 17:
                lengths += [Int](repeating: 0, count: 3 + (try reader.bits(3)))
            default:
                lengths += [Int](repeating: 0, count: 11 + (try reader.bits(7)))
            }
        }
        guard lengths.count == literalCount + distanceCount, lengths[256] != 0 else { throw .invalidCode }
        return (
            try Huffman(lengths: lengths[0..<literalCount]),
            try Huffman(lengths: lengths[literalCount...])
        )
    }

    private static func codes(
        _ reader: inout BitReader, literals: Huffman, distances: Huffman, into output: inout [UInt8], limit: Int
    ) throws(Failure) {
        while true {
            let symbol = try literals.decode(&reader)
            if symbol < 256 {
                guard output.count < limit else { throw .tooLarge(limit: limit) }
                output.append(UInt8(symbol))
            } else if symbol == 256 {
                return
            } else {
                let index = symbol - 257
                guard index < lengthBase.count else { throw .invalidCode }
                let length = lengthBase[index] + (try reader.bits(lengthExtra[index]))
                let distanceSymbol = try distances.decode(&reader)
                guard distanceSymbol < distanceBase.count else { throw .invalidDistance }
                let distance = distanceBase[distanceSymbol] + (try reader.bits(distanceExtra[distanceSymbol]))
                guard distance <= output.count else { throw .invalidDistance }
                guard output.count + length <= limit else { throw .tooLarge(limit: limit) }
                let start = output.count - distance
                for offset in 0..<length {
                    output.append(output[start + offset])
                }
            }
        }
    }
}

/// CRC-32（IEEE 802.3，反射多项式 0xEDB88320）：gzip 尾部校验与 VMess AuthID。
public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1
        }
        return value
    }

    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
