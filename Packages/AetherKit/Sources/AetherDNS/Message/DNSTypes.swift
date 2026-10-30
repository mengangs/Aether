/// DNS 记录类型（RFC 1035 §3.2.2 及后续 RFC）。未列出的类型以数值保留。
public struct DNSRecordType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let a = DNSRecordType(rawValue: 1)
    public static let ns = DNSRecordType(rawValue: 2)
    public static let cname = DNSRecordType(rawValue: 5)
    public static let soa = DNSRecordType(rawValue: 6)
    public static let ptr = DNSRecordType(rawValue: 12)
    public static let mx = DNSRecordType(rawValue: 15)
    public static let txt = DNSRecordType(rawValue: 16)
    public static let aaaa = DNSRecordType(rawValue: 28)
    public static let srv = DNSRecordType(rawValue: 33)
    public static let opt = DNSRecordType(rawValue: 41)
    public static let svcb = DNSRecordType(rawValue: 64)
    public static let https = DNSRecordType(rawValue: 65)
    public static let any = DNSRecordType(rawValue: 255)

    private static let names: [(DNSRecordType, String)] = [
        (.a, "A"), (.ns, "NS"), (.cname, "CNAME"), (.soa, "SOA"), (.ptr, "PTR"), (.mx, "MX"), (.txt, "TXT"),
        (.aaaa, "AAAA"), (.srv, "SRV"), (.opt, "OPT"), (.svcb, "SVCB"), (.https, "HTTPS"), (.any, "ANY"),
    ]

    /// 按名称（不区分大小写）或 `TYPE<数字>` 形式解析。
    public init?(name: String) {
        let upper = name.uppercased()
        if let match = Self.names.first(where: { $0.1 == upper }) {
            self = match.0
        } else if upper.hasPrefix("TYPE"), let value = UInt16(upper.dropFirst(4)) {
            self.init(rawValue: value)
        } else {
            return nil
        }
    }

    public var description: String {
        Self.names.first { $0.0 == self }?.1 ?? "TYPE\(rawValue)"
    }
}

/// DNS 类。只有 `IN` 有实际用途，其余以数值保留。
public struct DNSClass: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let internet = DNSClass(rawValue: 1)
}

/// 响应码（头部的 4 位 RCODE，不含 EDNS 扩展位）。
public struct DNSResponseCode: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue & 0x0F
    }

    public static let noError = DNSResponseCode(rawValue: 0)
    public static let formatError = DNSResponseCode(rawValue: 1)
    public static let serverFailure = DNSResponseCode(rawValue: 2)
    public static let nameError = DNSResponseCode(rawValue: 3)
    public static let notImplemented = DNSResponseCode(rawValue: 4)
    public static let refused = DNSResponseCode(rawValue: 5)

    public var description: String {
        switch rawValue {
        case 0: return "NOERROR"
        case 1: return "FORMERR"
        case 2: return "SERVFAIL"
        case 3: return "NXDOMAIN"
        case 4: return "NOTIMP"
        case 5: return "REFUSED"
        default: return "RCODE\(rawValue)"
        }
    }
}

/// 报文头（RFC 1035 §4.1.1）。
public struct DNSHeader: Hashable, Sendable {
    public var id: UInt16
    public var isResponse: Bool
    public var opcode: UInt8
    public var isAuthoritative: Bool
    public var isTruncated: Bool
    public var recursionDesired: Bool
    public var recursionAvailable: Bool
    public var authenticData: Bool
    public var checkingDisabled: Bool
    public var responseCode: DNSResponseCode

    public init(
        id: UInt16, isResponse: Bool = false, opcode: UInt8 = 0, isAuthoritative: Bool = false,
        isTruncated: Bool = false, recursionDesired: Bool = true, recursionAvailable: Bool = false,
        authenticData: Bool = false, checkingDisabled: Bool = false, responseCode: DNSResponseCode = .noError
    ) {
        self.id = id
        self.isResponse = isResponse
        self.opcode = opcode
        self.isAuthoritative = isAuthoritative
        self.isTruncated = isTruncated
        self.recursionDesired = recursionDesired
        self.recursionAvailable = recursionAvailable
        self.authenticData = authenticData
        self.checkingDisabled = checkingDisabled
        self.responseCode = responseCode
    }

    var flags: UInt16 {
        var value: UInt16 = 0
        if isResponse { value |= 0x8000 }
        value |= UInt16(opcode & 0x0F) << 11
        if isAuthoritative { value |= 0x0400 }
        if isTruncated { value |= 0x0200 }
        if recursionDesired { value |= 0x0100 }
        if recursionAvailable { value |= 0x0080 }
        if authenticData { value |= 0x0020 }
        if checkingDisabled { value |= 0x0010 }
        value |= UInt16(responseCode.rawValue)
        return value
    }

    init(id: UInt16, flags: UInt16) {
        self.init(
            id: id,
            isResponse: flags & 0x8000 != 0,
            opcode: UInt8((flags >> 11) & 0x0F),
            isAuthoritative: flags & 0x0400 != 0,
            isTruncated: flags & 0x0200 != 0,
            recursionDesired: flags & 0x0100 != 0,
            recursionAvailable: flags & 0x0080 != 0,
            authenticData: flags & 0x0020 != 0,
            checkingDisabled: flags & 0x0010 != 0,
            responseCode: DNSResponseCode(rawValue: UInt8(flags & 0x0F))
        )
    }
}

/// 域名（报文中的标签序列）。标签保留原始字节与大小写；比较与缓存键用 `normalized`（ASCII 小写）。
public struct DNSName: Hashable, Sendable, CustomStringConvertible {
    /// 标签上限 63 字节，整个名称（含长度字节与根）上限 255 字节（RFC 1035 §2.3.4）。
    public static let maxLabelLength = 63
    public static let maxWireLength = 255

    public let labels: [[UInt8]]

    public static let root = DNSName(uncheckedLabels: [])

    init(uncheckedLabels: [[UInt8]]) {
        labels = uncheckedLabels
    }

    /// 由标签构造；任一标签为空或超长、或总长度超限时返回 nil。
    public init?(labels: [[UInt8]]) {
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= Self.maxLabelLength }) else { return nil }
        let wire = labels.reduce(1) { $0 + 1 + $1.count }
        guard wire <= Self.maxWireLength else { return nil }
        self.labels = labels
    }

    /// 解析点分文本（允许末尾的点；`.` 或空串为根）。
    public init?(_ text: some StringProtocol) {
        var string = String(text)
        if string.hasSuffix(".") {
            string.removeLast()
        }
        if string.isEmpty {
            self = .root
            return
        }
        self.init(labels: string.split(separator: ".", omittingEmptySubsequences: false).map { Array($0.utf8) })
    }

    /// 编码后的长度（含根的 0 字节）。
    public var wireLength: Int {
        labels.reduce(1) { $0 + 1 + $1.count }
    }

    /// 点分文本，不含末尾的点；根为空串。
    public var text: String {
        labels.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ".")
    }

    /// ASCII 小写的点分文本（比较与缓存键）。
    public var normalized: String {
        labels.map { label in
            String(decoding: label.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 }, as: UTF8.self)
        }.joined(separator: ".")
    }

    public var description: String {
        labels.isEmpty ? "." : text
    }

    /// 不区分 ASCII 大小写比较。
    public func equalsIgnoringCase(_ other: DNSName) -> Bool {
        normalized == other.normalized
    }
}
