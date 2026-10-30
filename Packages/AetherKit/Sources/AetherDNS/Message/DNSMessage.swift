import AetherFoundation

/// 问题节条目。
public struct DNSQuestion: Hashable, Sendable {
    public var name: DNSName
    public var type: DNSRecordType
    public var dnsClass: DNSClass

    public init(name: DNSName, type: DNSRecordType, dnsClass: DNSClass = .internet) {
        self.name = name
        self.type = type
        self.dnsClass = dnsClass
    }
}

/// SOA 记录。
public struct DNSSOA: Hashable, Sendable {
    public var primaryServer: DNSName
    public var responsibleMailbox: DNSName
    public var serial: UInt32
    public var refresh: UInt32
    public var retry: UInt32
    public var expire: UInt32
    public var minimum: UInt32

    public init(
        primaryServer: DNSName, responsibleMailbox: DNSName, serial: UInt32, refresh: UInt32, retry: UInt32,
        expire: UInt32, minimum: UInt32
    ) {
        self.primaryServer = primaryServer
        self.responsibleMailbox = responsibleMailbox
        self.serial = serial
        self.refresh = refresh
        self.retry = retry
        self.expire = expire
        self.minimum = minimum
    }
}

/// SVCB / HTTPS 记录（RFC 9460）。参数按键保留原始字节。
public struct DNSServiceBinding: Hashable, Sendable {
    public struct Parameter: Hashable, Sendable {
        public var key: UInt16
        public var value: [UInt8]

        public init(key: UInt16, value: [UInt8]) {
            self.key = key
            self.value = value
        }
    }

    public var priority: UInt16
    public var target: DNSName
    public var parameters: [Parameter]

    public init(priority: UInt16, target: DNSName, parameters: [Parameter]) {
        self.priority = priority
        self.target = target
        self.parameters = parameters
    }
}

/// 记录数据。A、AAAA、CNAME、PTR、NS、SOA、SVCB、HTTPS 结构化，其余为不透明字节。
///
/// 不透明数据按报文中的原样保存：若该类型允许名称压缩（如 MX），其中可能含指向原报文的压缩指针。
/// 因此**不要重新编码解码得到的上游报文**——转发上游应答时直接改写原始字节（`DNSWire`）。
public enum DNSRecordData: Hashable, Sendable {
    case a(IPv4Address)
    case aaaa(IPv6Address)
    case cname(DNSName)
    case ptr(DNSName)
    case ns(DNSName)
    case soa(DNSSOA)
    case serviceBinding(DNSServiceBinding)
    case opaque([UInt8])
}

/// 资源记录。OPT 伪记录的 `dnsClass` 是 UDP 负载上限、`ttl` 是扩展 RCODE / 版本 / 标志（RFC 6891）。
public struct DNSResourceRecord: Hashable, Sendable {
    public var name: DNSName
    public var type: DNSRecordType
    public var dnsClass: DNSClass
    public var ttl: UInt32
    public var data: DNSRecordData

    public init(name: DNSName, type: DNSRecordType, dnsClass: DNSClass = .internet, ttl: UInt32, data: DNSRecordData) {
        self.name = name
        self.type = type
        self.dnsClass = dnsClass
        self.ttl = ttl
        self.data = data
    }

    /// A / AAAA 记录的地址。
    public var address: IPAddress? {
        switch data {
        case .a(let v4): return .v4(v4)
        case .aaaa(let v6): return .v6(v6)
        default: return nil
        }
    }
}

/// EDNS(0) 信息（来自附加节的 OPT 记录）。选项按原始字节保留。
public struct DNSEDNS: Hashable, Sendable {
    public var udpPayloadSize: UInt16
    public var extendedRCodeAndFlags: UInt32
    public var options: [UInt8]

    public init(udpPayloadSize: UInt16, extendedRCodeAndFlags: UInt32 = 0, options: [UInt8] = []) {
        self.udpPayloadSize = udpPayloadSize
        self.extendedRCodeAndFlags = extendedRCodeAndFlags
        self.options = options
    }

    /// 转为 OPT 伪记录。
    public var record: DNSResourceRecord {
        DNSResourceRecord(
            name: .root, type: .opt, dnsClass: DNSClass(rawValue: udpPayloadSize), ttl: extendedRCodeAndFlags,
            data: .opaque(options))
    }
}

/// DNS 报文（RFC 1035 §4）。
public struct DNSMessage: Hashable, Sendable {
    public var header: DNSHeader
    public var questions: [DNSQuestion]
    public var answers: [DNSResourceRecord]
    public var authorities: [DNSResourceRecord]
    public var additionals: [DNSResourceRecord]

    public init(
        header: DNSHeader, questions: [DNSQuestion] = [], answers: [DNSResourceRecord] = [],
        authorities: [DNSResourceRecord] = [], additionals: [DNSResourceRecord] = []
    ) {
        self.header = header
        self.questions = questions
        self.answers = answers
        self.authorities = authorities
        self.additionals = additionals
    }

    /// 附加节中的 EDNS(0) 信息。
    public var edns: DNSEDNS? {
        for record in additionals where record.type == .opt {
            if case .opaque(let options) = record.data {
                return DNSEDNS(
                    udpPayloadSize: record.dnsClass.rawValue, extendedRCodeAndFlags: record.ttl, options: options)
            }
        }
        return nil
    }

    /// 构造对 `query` 的响应骨架：相同 ID 与问题，QR=1、RA=1，复制 RD 与 CD；查询带 EDNS 时附带
    /// 声明 `udpPayloadSize` 的 OPT 记录。
    public static func response(
        to query: DNSMessage, code: DNSResponseCode = .noError, answers: [DNSResourceRecord] = [],
        udpPayloadSize: UInt16 = DNSWire.ednsPayloadSize
    ) -> DNSMessage {
        var header = DNSHeader(
            id: query.header.id, isResponse: true, opcode: query.header.opcode,
            recursionDesired: query.header.recursionDesired, recursionAvailable: true,
            checkingDisabled: query.header.checkingDisabled, responseCode: code)
        header.isAuthoritative = false
        let additionals = query.edns != nil ? [DNSEDNS(udpPayloadSize: udpPayloadSize).record] : []
        return DNSMessage(header: header, questions: query.questions, answers: answers, additionals: additionals)
    }
}

/// 报文解码失败（`DNS-005` 的细分原因，也用于拒绝格式错误的查询）。
public enum DNSDecodeError: Error, Hashable, Sendable {
    case truncated
    case labelTooLong
    case nameTooLong
    case badPointer
    case unsupportedLabelType
    case badRecordData
}

extension DNSMessage {
    /// 解码。名称压缩指针必须严格指向当前名称之前的位置（防止环），一个名称最多跟随 64 次指针。
    public static func decode(_ bytes: [UInt8]) throws(DNSDecodeError) -> DNSMessage {
        var reader = DNSReader(bytes: bytes)
        let id = try reader.readUInt16()
        let flags = try reader.readUInt16()
        let counts = (
            try reader.readUInt16(), try reader.readUInt16(), try reader.readUInt16(), try reader.readUInt16()
        )
        var message = DNSMessage(header: DNSHeader(id: id, flags: flags))
        message.questions.reserveCapacity(min(Int(counts.0), 4))
        for _ in 0..<counts.0 {
            let name = try reader.readName()
            let type = DNSRecordType(rawValue: try reader.readUInt16())
            let dnsClass = DNSClass(rawValue: try reader.readUInt16())
            message.questions.append(DNSQuestion(name: name, type: type, dnsClass: dnsClass))
        }
        message.answers = try reader.readRecords(count: counts.1)
        message.authorities = try reader.readRecords(count: counts.2)
        message.additionals = try reader.readRecords(count: counts.3)
        return message
    }

    /// 编码。名称（含 CNAME / PTR / NS / SOA 数据中的名称）按后缀压缩；SVCB / HTTPS 的目标名不压缩（RFC 9460）。
    public func encode() -> [UInt8] {
        var writer = DNSWriter()
        writer.writeUInt16(header.id)
        writer.writeUInt16(header.flags)
        writer.writeUInt16(UInt16(clamping: questions.count))
        writer.writeUInt16(UInt16(clamping: answers.count))
        writer.writeUInt16(UInt16(clamping: authorities.count))
        writer.writeUInt16(UInt16(clamping: additionals.count))
        for question in questions {
            writer.writeName(question.name, compress: true)
            writer.writeUInt16(question.type.rawValue)
            writer.writeUInt16(question.dnsClass.rawValue)
        }
        for record in answers + authorities + additionals {
            writer.writeRecord(record)
        }
        return writer.bytes
    }
}

// MARK: - 读写

struct DNSReader {
    let bytes: [UInt8]
    var offset = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func readUInt8() throws(DNSDecodeError) -> UInt8 {
        guard offset < bytes.count else { throw .truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func readUInt16() throws(DNSDecodeError) -> UInt16 {
        guard offset + 2 <= bytes.count else { throw .truncated }
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func readUInt32() throws(DNSDecodeError) -> UInt32 {
        guard offset + 4 <= bytes.count else { throw .truncated }
        defer { offset += 4 }
        return UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    mutating func readBytes(_ count: Int) throws(DNSDecodeError) -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw .truncated }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    /// 读取名称并前进到名称（首个指针）之后。
    mutating func readName() throws(DNSDecodeError) -> DNSName {
        var labels: [[UInt8]] = []
        var wireLength = 1
        var cursor = offset
        var resumeAt: Int?
        var jumps = 0
        // 指针只能指向「本名称开始之前」：每次跳转后上界更新为跳转目标，保证严格后退、不会成环。
        var limit = offset
        while true {
            guard cursor < bytes.count else { throw .truncated }
            let length = bytes[cursor]
            switch length & 0xC0 {
            case 0x00:
                if length == 0 {
                    offset = resumeAt ?? (cursor + 1)
                    return DNSName(uncheckedLabels: labels)
                }
                let count = Int(length)
                guard cursor + 1 + count <= bytes.count else { throw .truncated }
                wireLength += 1 + count
                guard wireLength <= DNSName.maxWireLength else { throw .nameTooLong }
                labels.append(Array(bytes[(cursor + 1)...(cursor + count)]))
                cursor += 1 + count
            case 0xC0:
                guard cursor + 1 < bytes.count else { throw .truncated }
                let target = Int(length & 0x3F) << 8 | Int(bytes[cursor + 1])
                guard target < limit, jumps < 64 else { throw .badPointer }
                if resumeAt == nil {
                    resumeAt = cursor + 2
                }
                jumps += 1
                limit = target
                cursor = target
            default:
                throw .unsupportedLabelType
            }
        }
    }

    mutating func readRecords(count: UInt16) throws(DNSDecodeError) -> [DNSResourceRecord] {
        var records: [DNSResourceRecord] = []
        records.reserveCapacity(min(Int(count), 16))
        for _ in 0..<count {
            records.append(try readRecord())
        }
        return records
    }

    mutating func readRecord() throws(DNSDecodeError) -> DNSResourceRecord {
        try readRecordWithTTLOffset().record
    }

    /// 读取一条记录，同时返回其 TTL 字段在报文中的偏移。
    mutating func readRecordWithTTLOffset() throws(DNSDecodeError) -> (record: DNSResourceRecord, ttlOffset: Int) {
        let name = try readName()
        let ttlOffset = offset + 4
        let type = DNSRecordType(rawValue: try readUInt16())
        let dnsClass = DNSClass(rawValue: try readUInt16())
        let ttl = try readUInt32()
        let length = Int(try readUInt16())
        guard offset + length <= bytes.count else { throw .truncated }
        let end = offset + length
        let data: DNSRecordData
        switch type {
        case .a:
            guard length == 4, let v4 = IPv4Address(bytes: bytes[offset..<end]) else { throw .badRecordData }
            data = .a(v4)
            offset = end
        case .aaaa:
            guard length == 16, let v6 = IPv6Address(bytes: bytes[offset..<end]) else { throw .badRecordData }
            data = .aaaa(v6)
            offset = end
        case .cname, .ptr, .ns:
            let target = try readName()
            guard offset == end else { throw .badRecordData }
            data = type == .cname ? .cname(target) : type == .ptr ? .ptr(target) : .ns(target)
        case .soa:
            let primary = try readName()
            let mailbox = try readName()
            let soa = DNSSOA(
                primaryServer: primary, responsibleMailbox: mailbox, serial: try readUInt32(),
                refresh: try readUInt32(), retry: try readUInt32(), expire: try readUInt32(),
                minimum: try readUInt32())
            guard offset == end else { throw .badRecordData }
            data = .soa(soa)
        case .svcb, .https:
            let priority = try readUInt16()
            let target = try readName()
            var parameters: [DNSServiceBinding.Parameter] = []
            while offset < end {
                let key = try readUInt16()
                let valueLength = Int(try readUInt16())
                guard offset + valueLength <= end else { throw .badRecordData }
                parameters.append(.init(key: key, value: try readBytes(valueLength)))
            }
            guard offset == end else { throw .badRecordData }
            data = .serviceBinding(DNSServiceBinding(priority: priority, target: target, parameters: parameters))
        default:
            data = .opaque(try readBytes(length))
        }
        return (DNSResourceRecord(name: name, type: type, dnsClass: dnsClass, ttl: ttl, data: data), ttlOffset)
    }
}

struct DNSWriter {
    private(set) var bytes: [UInt8] = []
    /// 已写出名称后缀（规范化文本）→ 偏移，用于压缩。只记录 0x3FFF 以内的偏移。
    private var suffixOffsets: [String: Int] = [:]

    init() {
        bytes.reserveCapacity(512)
    }

    mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func writeUInt16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func writeUInt32(_ value: UInt32) {
        writeUInt16(UInt16(value >> 16))
        writeUInt16(UInt16(value & 0xFFFF))
    }

    mutating func writeName(_ name: DNSName, compress: Bool) {
        let labels = name.labels
        for index in labels.indices {
            let suffix = DNSName(uncheckedLabels: Array(labels[index...])).normalized
            if compress, let target = suffixOffsets[suffix] {
                writeUInt16(0xC000 | UInt16(target))
                return
            }
            if compress, bytes.count <= 0x3FFF {
                suffixOffsets[suffix] = bytes.count
            }
            writeUInt8(UInt8(labels[index].count))
            bytes.append(contentsOf: labels[index])
        }
        writeUInt8(0)
    }

    mutating func writeRecord(_ record: DNSResourceRecord) {
        writeName(record.name, compress: true)
        writeUInt16(record.type.rawValue)
        writeUInt16(record.dnsClass.rawValue)
        writeUInt32(record.ttl)
        let lengthOffset = bytes.count
        writeUInt16(0)
        switch record.data {
        case .a(let v4): bytes.append(contentsOf: v4.bytes)
        case .aaaa(let v6): bytes.append(contentsOf: v6.bytes)
        case .cname(let name), .ptr(let name), .ns(let name): writeName(name, compress: true)
        case .soa(let soa):
            writeName(soa.primaryServer, compress: true)
            writeName(soa.responsibleMailbox, compress: true)
            writeUInt32(soa.serial)
            writeUInt32(soa.refresh)
            writeUInt32(soa.retry)
            writeUInt32(soa.expire)
            writeUInt32(soa.minimum)
        case .serviceBinding(let binding):
            writeUInt16(binding.priority)
            writeName(binding.target, compress: false)
            for parameter in binding.parameters {
                writeUInt16(parameter.key)
                writeUInt16(UInt16(clamping: parameter.value.count))
                bytes.append(contentsOf: parameter.value)
            }
        case .opaque(let raw): bytes.append(contentsOf: raw)
        }
        let length = bytes.count - lengthOffset - 2
        bytes[lengthOffset] = UInt8((length >> 8) & 0xFF)
        bytes[lengthOffset + 1] = UInt8(length & 0xFF)
    }
}
