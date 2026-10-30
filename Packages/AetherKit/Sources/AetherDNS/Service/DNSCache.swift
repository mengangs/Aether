import AetherFoundation
import NIOCore

/// DNS 错误（docs/07 §9）。
public struct DNSError: AetherErrorProtocol, Hashable {
    public let code: AetherErrorCode
    public let details: String

    public init(_ code: AetherErrorCode, _ details: String = "") {
        self.code = code
        self.details = details
    }

    public var debugDetails: String {
        details.isEmpty ? code.rawValue : details
    }

    public var isRetryable: Bool {
        code == .dnsTimeout || code == .dnsServerFailure || code == .dnsUpstreamUnreachable
    }
}

extension AetherErrorCode {
    /// 查询超时。
    public static let dnsTimeout: AetherErrorCode = "DNS-001"
    /// 上游返回 SERVFAIL。
    public static let dnsServerFailure: AetherErrorCode = "DNS-002"
    /// 域名不存在（NXDOMAIN）。
    public static let dnsNameError: AetherErrorCode = "DNS-003"
    /// 无法连接上游。
    public static let dnsUpstreamUnreachable: AetherErrorCode = "DNS-004"
    /// 上游响应格式错误。
    public static let dnsMalformedResponse: AetherErrorCode = "DNS-005"
    /// 加密 DNS 的 TLS 失败。
    public static let dnsTLSFailure: AetherErrorCode = "DNS-006"
    /// Fake IP 地址池已满，开始回收。
    public static let dnsFakeIPRecycling: AetherErrorCode = "DNS-010"
    /// 没有可用的系统 DNS 服务器。
    public static let dnsNoSystemServers: AetherErrorCode = "DNS-011"
}

/// 缓存键：规范化域名 + 类型 + 类 + 上游组（docs/07 §5）。
public struct DNSCacheKey: Hashable, Sendable {
    public var name: String
    public var type: DNSRecordType
    public var dnsClass: DNSClass
    /// 上游组标识（`plain`、`encrypted` 或 `[Host]` 指定的上游原文）。
    public var group: String

    public init(name: String, type: DNSRecordType, dnsClass: DNSClass = .internet, group: String) {
        self.name = name
        self.type = type
        self.dnsClass = dnsClass
        self.group = group
    }
}

/// 一次上游查询的结果（缓存条目的内容）。
public struct DNSUpstreamAnswer: Sendable {
    /// 上游返回的原始报文（ID 为任意值，使用前改写）。
    public var response: [UInt8]
    public var scanned: DNSWire.ScannedResponse
    /// 应答的上游名称。
    public var upstream: String
    /// 是否来自 `system` 上游（网络变化时失效）。
    public var fromSystem: Bool
    /// 上游耗时。
    public var duration: TimeAmount

    public init(
        response: [UInt8], scanned: DNSWire.ScannedResponse, upstream: String, fromSystem: Bool, duration: TimeAmount
    ) {
        self.response = response
        self.scanned = scanned
        self.upstream = upstream
        self.fromSystem = fromSystem
        self.duration = duration
    }

    public var responseCode: DNSResponseCode { scanned.message.header.responseCode }
}

/// 正向与否定缓存（docs/07 §5）。LRU 4,096 条；容量满时淘汰最久未用的条目。
///
/// 不是线程安全的：由 `DNSService` 持有，只在数据面 EventLoop 上使用。
public struct DNSCache {
    public static let defaultCapacity = 4096

    /// 正向 TTL 的上下限、否定缓存的上下限、SERVFAIL 的缓存时长。
    public static let positiveTTLRange: ClosedRange<Int64> = 10...86_400
    public static let negativeTTLRange: ClosedRange<Int64> = 10...300
    public static let serverFailureTTL: Int64 = 5

    public struct Entry: Sendable {
        public var answer: DNSUpstreamAnswer
        public var storedAt: NIODeadline
        public var expiresAt: NIODeadline
    }

    private var storage: LRUCache<DNSCacheKey, Entry>

    public init(capacity: Int = DNSCache.defaultCapacity) {
        storage = LRUCache(capacity: capacity)
    }

    public var count: Int { storage.count }

    /// 应缓存的秒数：NOERROR 且有答案按最小 TTL（10 秒–1 天）；NXDOMAIN / NODATA 按 SOA（10–300 秒，无 SOA 取 10 秒）；
    /// SERVFAIL 5 秒；其余（REFUSED 等）不缓存。
    public static func lifetime(for answer: DNSUpstreamAnswer) -> Int64? {
        let scanned = answer.scanned
        switch answer.responseCode {
        case .noError where scanned.hasAnswerForQuestion:
            let ttl = Int64(scanned.minimumAnswerTTL ?? 0)
            return min(max(ttl, positiveTTLRange.lowerBound), positiveTTLRange.upperBound)
        case .noError, .nameError:
            let ttl = Int64(scanned.negativeTTL ?? 0)
            return min(max(ttl, negativeTTLRange.lowerBound), negativeTTLRange.upperBound)
        case .serverFailure:
            return serverFailureTTL
        default:
            return nil
        }
    }

    /// 读取未过期的条目（过期条目顺带删除）。
    public mutating func lookup(_ key: DNSCacheKey, now: NIODeadline) -> Entry? {
        guard let entry = storage.get(key) else { return nil }
        if entry.expiresAt <= now {
            storage.remove(key)
            return nil
        }
        return entry
    }

    /// 写入（不可缓存的应答被忽略）。
    public mutating func store(_ answer: DNSUpstreamAnswer, for key: DNSCacheKey, now: NIODeadline) {
        guard let seconds = Self.lifetime(for: answer) else { return }
        storage.set(key, Entry(answer: answer, storedAt: now, expiresAt: now + .seconds(seconds)))
    }

    /// 网络变化：清空来自 `system` 上游的条目。
    public mutating func removeSystemEntries() {
        for key in storage.keysByRecency where storage.peek(key)?.answer.fromSystem == true {
            storage.remove(key)
        }
    }

    public mutating func removeAll() {
        storage.removeAll()
    }

    /// 条目列表，最近使用在前（IPC `getDNSCache`）。
    public func entries(offset: Int = 0, limit: Int = .max) -> [(key: DNSCacheKey, entry: Entry)] {
        storage.keysByRecency.dropFirst(offset).prefix(limit).compactMap { key in
            storage.peek(key).map { (key, $0) }
        }
    }
}

/// DNS 反查表（docs/07 §6）：真实 IP → 最近一次对应的域名，LRU 4,096 条。
public struct ReverseTable {
    private var storage: LRUCache<IPAddress, String>

    public init(capacity: Int = 4096) {
        storage = LRUCache(capacity: capacity)
    }

    public var count: Int { storage.count }

    public mutating func record(_ addresses: [IPAddress], domain: String) {
        for address in addresses {
            storage.set(address.unmappedIPv4, domain)
        }
    }

    public mutating func domain(for address: IPAddress) -> String? {
        storage.get(address.unmappedIPv4)
    }

    public mutating func removeAll() {
        storage.removeAll()
    }
}
