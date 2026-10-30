import AetherFoundation

/// Fake IP 地址池（docs/07 §3）：在 `fake-ip-range` 内为域名分配地址，维护双向映射，按最近使用淘汰。
///
/// - 保留网络地址、`.1`（TUN 接口）、`.2`（DNS 服务）与广播地址，不分配；
/// - 查询与连接都算「使用」；地址用尽时回收最久未用的映射（首次回收时 `didStartRecycling` 置位，
///   调用方据此写一次 `DNS-010` 日志）；
/// - 容量即可用地址数（默认 /15 约 13 万），映射随使用增长，不预先分配。
///
/// 不是线程安全的：由 `DNSService` 持有，只在数据面 EventLoop 上使用。
public final class FakeIPPool {
    /// 持久化文件的魔数与版本（docs/07 §3.2）。
    static let magic: [UInt8] = Array("AEFI".utf8)
    static let formatVersion: UInt8 = 1
    /// 持久化时写入的最近使用条目数。
    public static let persistedEntryLimit = 16_384

    public let range: CIDR
    private let base: UInt32
    private let size: UInt32
    /// 规范化域名 → 地址偏移，按最近使用排序。
    private var byDomain: LRUCache<String, UInt32>
    private var byOffset: [UInt32: String] = [:]
    /// 尚未分配过的下一个偏移。
    private var nextFresh: UInt32 = 0
    /// 是否已经开始回收（地址用尽）。
    public private(set) var didStartRecycling = false

    /// - Parameter range: IPv4 地址块，前缀 ≤ 30（至少 4 个地址）；不满足时退回默认的 `198.18.0.0/15`。
    public init(range: CIDR) {
        let fallback = CIDR(ipv4: IPv4Address(198, 18, 0, 0), prefixLength: 15)
        let effective: CIDR
        if case .v4 = range.network, range.prefixLength <= 30 {
            effective = range
        } else {
            effective = fallback
        }
        self.range = effective
        guard case .v4(let network) = effective.network else {
            preconditionFailure("Fake IP range must be IPv4")
        }
        base = network.value
        size = UInt32(1) << UInt32(32 - effective.prefixLength)
        byDomain = LRUCache(capacity: Int(size) - 4)
    }

    /// 可分配的地址数。
    public var capacity: Int { byDomain.capacity }

    /// 当前映射数。
    public var count: Int { byDomain.count }

    /// 地址是否落在 Fake IP 段内（含保留地址）。
    public func contains(_ address: IPAddress) -> Bool {
        range.contains(address)
    }

    /// 为域名取得 Fake IP：已有映射则返回并标记为最近使用，否则分配（必要时回收最久未用的映射）。
    public func address(for domain: String) -> IPv4Address {
        if let offset = byDomain.get(domain) {
            return IPv4Address(base &+ offset)
        }
        let offset: UInt32
        if let fresh = takeFreshOffset() {
            offset = fresh
        } else if let evicted = byDomain.popLeastRecent() {
            didStartRecycling = true
            byOffset[evicted.value] = nil
            offset = evicted.value
        } else {
            offset = 3
        }
        byDomain.set(domain, offset)
        byOffset[offset] = domain
        return IPv4Address(base &+ offset)
    }

    /// 反查：地址映射的域名；同时标记为最近使用。未映射（或已被回收）时为 nil。
    public func domain(for address: IPAddress) -> String? {
        guard case .v4(let v4) = address.unmappedIPv4, range.contains(address) else { return nil }
        let offset = v4.value &- base
        guard let domain = byOffset[offset] else { return nil }
        _ = byDomain.get(domain)
        return domain
    }

    /// 全部映射，最近使用在前（IPC `getFakeIPMappings`）。
    public func mappings(offset: Int = 0, limit: Int = .max) -> [(domain: String, address: IPv4Address)] {
        byDomain.keysByRecency.dropFirst(offset).prefix(limit).compactMap { domain in
            byDomain.peek(domain).map { (domain, IPv4Address(base &+ $0)) }
        }
    }

    private func takeFreshOffset() -> UInt32? {
        while nextFresh < size {
            let candidate = nextFresh
            nextFresh += 1
            if Self.isReserved(offset: candidate, size: size) || byOffset[candidate] != nil {
                continue
            }
            return candidate
        }
        return nil
    }

    /// 网络地址、`.1`、`.2` 与广播地址。
    static func isReserved(offset: UInt32, size: UInt32) -> Bool {
        offset <= 2 || offset == size - 1
    }

    // MARK: - 持久化（docs/07 §3.2）

    /// 序列化最近使用的 `limit` 条映射：魔数、版本、条目数，之后为 `(偏移 UInt32, 域名长度 UInt8, 域名 UTF-8)`，
    /// 最近使用在前，整数大端。
    public func serialize(limit: Int = FakeIPPool.persistedEntryLimit) -> [UInt8] {
        let entries = byDomain.keysByRecency.prefix(limit).compactMap { domain -> (UInt32, [UInt8])? in
            let name = Array(domain.utf8)
            guard name.count <= 255, let offset = byDomain.peek(domain) else { return nil }
            return (offset, name)
        }
        var bytes = Self.magic
        bytes.append(Self.formatVersion)
        Bytes.appendBigEndian(UInt32(entries.count), to: &bytes)
        for (offset, name) in entries {
            Bytes.appendBigEndian(offset, to: &bytes)
            bytes.append(UInt8(name.count))
            bytes.append(contentsOf: name)
        }
        return bytes
    }

    /// 载入快照（隧道启动时）。格式不符时丢弃整个文件并返回 false；越界或保留的偏移逐条跳过。
    /// 载入的映射替换当前全部映射。
    @discardableResult
    public func load(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 9, Array(bytes[0..<4]) == Self.magic, bytes[4] == Self.formatVersion else {
            return false
        }
        let count = Int(Bytes.readBigEndian(UInt32.self, from: bytes, at: 5) ?? 0)
        var entries: [(UInt32, String)] = []
        var cursor = 9
        for _ in 0..<count {
            guard cursor + 5 <= bytes.count, let offset = Bytes.readBigEndian(UInt32.self, from: bytes, at: cursor)
            else { return false }
            let length = Int(bytes[cursor + 4])
            cursor += 5
            guard cursor + length <= bytes.count else { return false }
            let name = String(decoding: bytes[cursor..<(cursor + length)], as: UTF8.self)
            cursor += length
            entries.append((offset, name))
        }
        byDomain.removeAll()
        byOffset.removeAll()
        nextFresh = 0
        didStartRecycling = false
        // 文件中最近使用在前；倒序插入以恢复相同的最近使用顺序。
        for (offset, name) in entries.reversed() {
            guard offset < size, !Self.isReserved(offset: offset, size: size), !name.isEmpty,
                byDomain.peek(name) == nil, byOffset[offset] == nil, byDomain.count < byDomain.capacity
            else { continue }
            byDomain.set(name, offset)
            byOffset[offset] = name
        }
        return true
    }
}
