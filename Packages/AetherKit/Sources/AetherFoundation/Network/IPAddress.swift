/// IPv4 / IPv6 地址（docs/02 §3.1）。值类型，无分配；IPv4 映射的 IPv6 地址（`::ffff:a.b.c.d`）可经 `unmappedIPv4` 转回 IPv4。
public enum IPAddress: Hashable, Sendable, Comparable, CustomStringConvertible {
    case v4(IPv4Address)
    case v6(IPv6Address)

    /// 解析点分十进制 IPv4 或 RFC 4291 文本形式的 IPv6（允许 `::` 压缩与内嵌 IPv4；不接受区域 ID 与方括号）。
    public init?(_ text: some StringProtocol) {
        if let v4 = IPv4Address(text) {
            self = .v4(v4)
        } else if let v6 = IPv6Address(text) {
            self = .v6(v6)
        } else {
            return nil
        }
    }

    public var description: String {
        switch self {
        case .v4(let address): return address.description
        case .v6(let address): return address.description
        }
    }

    public var isIPv4: Bool {
        if case .v4 = self { return true }
        return false
    }

    /// IPv4 映射的 IPv6 地址返回对应 IPv4，其它返回自身。规则匹配按 IPv4 处理映射地址（docs/05 §3.3）。
    public var unmappedIPv4: IPAddress {
        if case .v6(let v6) = self, let v4 = v6.mappedIPv4 {
            return .v4(v4)
        }
        return self
    }

    /// 网络字节序的原始字节（4 或 16 字节）。
    public var bytes: [UInt8] {
        switch self {
        case .v4(let address): return address.bytes
        case .v6(let address): return address.bytes
        }
    }

    /// 从 4 或 16 字节构造。
    public init?(bytes: some Collection<UInt8>) {
        if let v4 = IPv4Address(bytes: bytes) {
            self = .v4(v4)
        } else if let v6 = IPv6Address(bytes: bytes) {
            self = .v6(v6)
        } else {
            return nil
        }
    }

    /// IPv4 排在 IPv6 之前，同族按数值。
    public static func < (lhs: IPAddress, rhs: IPAddress) -> Bool {
        switch (lhs, rhs) {
        case (.v4(let a), .v4(let b)): return a.value < b.value
        case (.v6(let a), .v6(let b)): return (a.high, a.low) < (b.high, b.low)
        case (.v4, .v6): return true
        case (.v6, .v4): return false
        }
    }
}

/// IPv4 地址，以主机字节序的 `UInt32` 保存。
public struct IPv4Address: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var value: UInt32

    public init(_ value: UInt32) {
        self.value = value
    }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    /// 严格的点分十进制：四段、每段 0–255、不允许前导零（`01`）与空白。
    public init?(_ text: some StringProtocol) {
        var result: UInt32 = 0
        var octet: UInt32 = 0
        var digits = 0
        var parts = 0
        for byte in text.utf8 {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"):
                if digits > 0, octet == 0 { return nil }
                octet = octet * 10 + UInt32(byte - UInt8(ascii: "0"))
                digits += 1
                if octet > 255 || digits > 3 { return nil }
            case UInt8(ascii: "."):
                guard digits > 0, parts < 3 else { return nil }
                result = result << 8 | octet
                parts += 1
                octet = 0
                digits = 0
            default:
                return nil
            }
        }
        guard digits > 0, parts == 3 else { return nil }
        value = result << 8 | octet
    }

    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 4 else { return nil }
        value = bytes.reduce(0) { $0 << 8 | UInt32($1) }
    }

    public var bytes: [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    public var description: String {
        "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)"
    }

    public static func < (lhs: IPv4Address, rhs: IPv4Address) -> Bool {
        lhs.value < rhs.value
    }
}

/// IPv6 地址，以两个主机字节序的 `UInt64` 保存（高 64 位、低 64 位）。
public struct IPv6Address: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var high: UInt64
    public var low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    public init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 16 else { return nil }
        let array = Array(bytes)
        high = array[0..<8].reduce(0) { $0 << 8 | UInt64($1) }
        low = array[8..<16].reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// RFC 4291 §2.2 文本形式。
    public init?(_ text: some StringProtocol) {
        let string = String(text)
        guard !string.isEmpty, string.utf8.count <= 45 else { return nil }
        var groups: [UInt16] = []
        var compressAt: Int?

        let halves = string.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }

        func parseGroups(_ part: String, allowV4Tail: Bool) -> [UInt16]? {
            if part.isEmpty { return [] }
            var result: [UInt16] = []
            let pieces = part.split(separator: ":", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if index == pieces.count - 1, allowV4Tail, piece.contains(".") {
                    guard let v4 = IPv4Address(piece) else { return nil }
                    result.append(UInt16(v4.value >> 16))
                    result.append(UInt16(v4.value & 0xFFFF))
                    continue
                }
                guard (1...4).contains(piece.count), let value = UInt16(piece, radix: 16) else { return nil }
                result.append(value)
            }
            return result
        }

        if halves.count == 2 {
            guard let head = parseGroups(halves[0], allowV4Tail: false),
                let tail = parseGroups(halves[1], allowV4Tail: true)
            else { return nil }
            guard head.count + tail.count <= 7 else { return nil }
            compressAt = head.count
            groups = head + tail
        } else {
            guard let all = parseGroups(halves[0], allowV4Tail: true), all.count == 8 else { return nil }
            groups = all
        }
        if let at = compressAt {
            groups.insert(contentsOf: [UInt16](repeating: 0, count: 8 - groups.count), at: at)
        }
        guard groups.count == 8 else { return nil }
        high = groups[0..<4].reduce(0) { $0 << 16 | UInt64($1) }
        low = groups[4..<8].reduce(0) { $0 << 16 | UInt64($1) }
    }

    public var bytes: [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(16)
        for word in [high, low] {
            for shift in stride(from: 56, through: 0, by: -8) {
                result.append(UInt8(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return result
    }

    /// `::ffff:a.b.c.d` 时返回内嵌的 IPv4。
    public var mappedIPv4: IPv4Address? {
        guard high == 0, low >> 32 == 0xFFFF else { return nil }
        return IPv4Address(UInt32(truncatingIfNeeded: low))
    }

    /// IPv4 映射地址。
    public init(mapping v4: IPv4Address) {
        high = 0
        low = 0xFFFF << 32 | UInt64(v4.value)
    }

    var groups: [UInt16] {
        var result: [UInt16] = []
        result.reserveCapacity(8)
        for word in [high, low] {
            for shift in stride(from: 48, through: 0, by: -16) {
                result.append(UInt16(truncatingIfNeeded: word >> UInt64(shift)))
            }
        }
        return result
    }

    /// RFC 5952 规范文本：小写、最长零段压缩（长度 ≥ 2，取最先出现者），IPv4 映射地址写成 `::ffff:a.b.c.d`。
    public var description: String {
        if let v4 = mappedIPv4 {
            return "::ffff:\(v4)"
        }
        let groups = self.groups
        var bestStart = -1
        var bestLength = 0
        var index = 0
        while index < 8 {
            if groups[index] == 0 {
                var end = index
                while end < 8, groups[end] == 0 { end += 1 }
                if end - index > bestLength {
                    bestStart = index
                    bestLength = end - index
                }
                index = end
            } else {
                index += 1
            }
        }
        let hex = groups.map { String($0, radix: 16) }
        guard bestLength >= 2 else { return hex.joined(separator: ":") }
        let head = hex[0..<bestStart].joined(separator: ":")
        let tail = hex[(bestStart + bestLength)...].joined(separator: ":")
        return head + "::" + tail
    }

    public static func < (lhs: IPv6Address, rhs: IPv6Address) -> Bool {
        (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }
}
