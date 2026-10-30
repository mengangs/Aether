import AetherFoundation

/// 原始报文层面的操作：改写事务 ID、改写 TTL、截断（docs/07 §2.1）。转发上游应答时只改这些字段，
/// 其余字节原样返回。
public enum DNSWire {
    /// 查询未带 EDNS 时的 UDP 响应上限（RFC 1035）。
    public static let classicUDPSize = 512
    /// 本端声明与采用的 EDNS UDP 负载上限（DNS Flag Day 2020 建议值）。
    public static let ednsPayloadSize: UInt16 = 1232
    /// 报文最小长度（头部）。
    public static let headerLength = 12

    /// 读取事务 ID；不足 2 字节时为 nil。
    public static func id(of bytes: [UInt8]) -> UInt16? {
        guard bytes.count >= 2 else { return nil }
        return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
    }

    /// 改写事务 ID。
    public static func setID(_ id: UInt16, in bytes: inout [UInt8]) {
        guard bytes.count >= 2 else { return }
        bytes[0] = UInt8(id >> 8)
        bytes[1] = UInt8(id & 0xFF)
    }

    /// 对查询的 UDP 响应长度上限：查询带 EDNS 时取其声明值与 1232 的较小者（不低于 512），否则 512。
    public static func udpLimit(for query: DNSMessage) -> Int {
        guard let edns = query.edns else { return classicUDPSize }
        return max(classicUDPSize, min(Int(edns.udpPayloadSize), Int(ednsPayloadSize)))
    }

    /// 超过 `limit` 的响应改为只含头部与问题节、置 TC 位的截断响应，客户端会改用 TCP 重试。
    public static func truncateIfNeeded(_ response: [UInt8], query: DNSMessage, limit: Int) -> [UInt8] {
        guard response.count > limit else { return response }
        var truncated = DNSMessage.response(to: query)
        if let decoded = try? DNSMessage.decode(response) {
            truncated.header.responseCode = decoded.header.responseCode
        }
        truncated.header.isTruncated = true
        return truncated.encode()
    }

    /// 解码上游应答，并记录每条记录 TTL 字段的偏移（不含 OPT），供缓存改写剩余 TTL。
    public static func scan(_ bytes: [UInt8]) throws(DNSDecodeError) -> ScannedResponse {
        var reader = DNSReader(bytes: bytes)
        let id = try reader.readUInt16()
        let flags = try reader.readUInt16()
        let qd = try reader.readUInt16()
        let an = try reader.readUInt16()
        let ns = try reader.readUInt16()
        let ar = try reader.readUInt16()
        var message = DNSMessage(header: DNSHeader(id: id, flags: flags))
        var questionEnd = headerLength
        for _ in 0..<qd {
            let name = try reader.readName()
            let type = DNSRecordType(rawValue: try reader.readUInt16())
            let dnsClass = DNSClass(rawValue: try reader.readUInt16())
            message.questions.append(DNSQuestion(name: name, type: type, dnsClass: dnsClass))
            questionEnd = reader.offset
        }
        var ttlFields: [ScannedResponse.TTLField] = []
        func records(_ count: UInt16) throws(DNSDecodeError) -> [DNSResourceRecord] {
            var result: [DNSResourceRecord] = []
            for _ in 0..<count {
                let (record, ttlOffset) = try reader.readRecordWithTTLOffset()
                if record.type != .opt {
                    ttlFields.append(.init(offset: ttlOffset, original: record.ttl))
                }
                result.append(record)
            }
            return result
        }
        message.answers = try records(an)
        message.authorities = try records(ns)
        message.additionals = try records(ar)
        return ScannedResponse(message: message, questionEnd: questionEnd, ttlFields: ttlFields)
    }

    /// 把各 TTL 字段改为「原值减去已缓存秒数」（不低于 `floor`）。
    public static func ageTTLs(
        in bytes: inout [UInt8], fields: [ScannedResponse.TTLField], elapsedSeconds: UInt32,
        floor: UInt32 = 1
    ) {
        for field in fields where field.offset + 4 <= bytes.count {
            let value = field.original > elapsedSeconds ? max(floor, field.original - elapsedSeconds) : floor
            bytes[field.offset] = UInt8(value >> 24)
            bytes[field.offset + 1] = UInt8((value >> 16) & 0xFF)
            bytes[field.offset + 2] = UInt8((value >> 8) & 0xFF)
            bytes[field.offset + 3] = UInt8(value & 0xFF)
        }
    }

    /// 把响应问题节中的名称字节替换为查询中的拼写（大小写可能不同，长度相同才替换）。
    public static func copyQuestionName(from query: [UInt8], into response: inout [UInt8]) {
        guard query.count > headerLength, response.count > headerLength else { return }
        guard let queryEnd = uncompressedNameEnd(query, from: headerLength),
            let responseEnd = uncompressedNameEnd(response, from: headerLength), queryEnd == responseEnd
        else { return }
        response.replaceSubrange(headerLength..<responseEnd, with: query[headerLength..<queryEnd])
    }

    private static func uncompressedNameEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var cursor = start
        while cursor < bytes.count {
            let length = Int(bytes[cursor])
            if length == 0 { return cursor + 1 }
            guard length & 0xC0 == 0 else { return nil }
            cursor += 1 + length
        }
        return nil
    }

    /// `scan` 的结果。
    public struct ScannedResponse: Sendable {
        public struct TTLField: Sendable, Hashable {
            public var offset: Int
            public var original: UInt32
        }

        public var message: DNSMessage
        /// 问题节结束的偏移。
        public var questionEnd: Int
        public var ttlFields: [TTLField]

        /// 应答节中的全部 A / AAAA 地址（含 CNAME 链末端）。
        public var addresses: [IPAddress] {
            message.answers.compactMap(\.address)
        }

        /// 应答节中是否有与问题类型相同的记录（区分 NOERROR 有答案与 NODATA）。
        public var hasAnswerForQuestion: Bool {
            guard let type = message.questions.first?.type else { return !message.answers.isEmpty }
            return message.answers.contains { $0.type == type || type == .any }
        }

        /// 正向缓存时长依据：应答节中最小的 TTL。
        public var minimumAnswerTTL: UInt32? {
            message.answers.map(\.ttl).min()
        }

        /// 否定缓存时长依据：权威节 SOA 的 min(TTL, MINIMUM)（RFC 2308 §5）。
        public var negativeTTL: UInt32? {
            for record in message.authorities {
                if case .soa(let soa) = record.data {
                    return min(record.ttl, soa.minimum)
                }
            }
            return nil
        }
    }
}
