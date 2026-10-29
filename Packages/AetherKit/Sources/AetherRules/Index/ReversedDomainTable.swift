/// 排序反转域名表（docs/05 §4.2）：后缀匹配与域名集共用。
///
/// 每个域名按标签反转（`www.example.com` → `com.example.www`），存入一块连续的 UTF-8 缓冲，
/// 另有偏移数组与值数组；条目按反转串排序。查询时依次二分查找主机名的每个后缀。
/// 内存约为"域名总字节数 + 每条 12 字节"。构建后不可变。
public struct ReversedDomainTable: Sendable {
    /// 一个键上的两类条目：精确（只匹配自身）与后缀（匹配自身及子域名），值为规则序号（越小越优先）。
    public struct Entry: Sendable, Equatable {
        public var exact: Int32?
        public var suffix: Int32?
    }

    private var buffer: [UInt8] = []
    private var offsets: [UInt32] = []  // 每条的起始位置；结束位置为下一条起始或缓冲末尾
    private var entries: [Entry] = []

    public var count: Int { entries.count }
    /// 估算的内存占用（字节）。
    public var estimatedBytes: Int { buffer.count + offsets.count * 4 + entries.count * 10 }

    public init() {}

    /// 由编译缓存中的原始数组恢复；数组不一致或键未排序时返回 nil。
    init?(buffer: [UInt8], offsets: [UInt32], entries: [Entry]) {
        guard offsets.count == entries.count else { return nil }
        var previous: ArraySlice<UInt8>?
        for (index, offset) in offsets.enumerated() {
            let start = Int(offset)
            let end = index + 1 < offsets.count ? Int(offsets[index + 1]) : buffer.count
            guard start <= end, end <= buffer.count else { return nil }
            let key = buffer[start..<end]
            if let previous, !previous.lexicographicallyPrecedes(key) { return nil }
            previous = key
        }
        self.buffer = buffer
        self.offsets = offsets
        self.entries = entries
    }

    var rawBuffer: [UInt8] { buffer }
    var rawOffsets: [UInt32] { offsets }
    var rawEntries: [Entry] { entries }

    /// 构建器：收集 `(域名, 是否后缀, 值)`，同键同类保留最小值。
    public struct Builder {
        private var items: [String: Entry] = [:]

        public init() {}

        public mutating func add(domain: String, isSuffix: Bool, value: Int) {
            let key = ReversedDomainTable.reversed(domain)
            var entry = items[key] ?? Entry()
            let v = Int32(clamping: value)
            if isSuffix {
                entry.suffix = min(entry.suffix ?? .max, v)
            } else {
                entry.exact = min(entry.exact ?? .max, v)
            }
            items[key] = entry
        }

        public var isEmpty: Bool { items.isEmpty }

        public func build() -> ReversedDomainTable {
            var table = ReversedDomainTable()
            let keys = items.keys.map { Array($0.utf8) }.sorted { $0.lexicographicallyPrecedes($1) }
            table.offsets.reserveCapacity(keys.count)
            table.entries.reserveCapacity(keys.count)
            for key in keys {
                table.offsets.append(UInt32(table.buffer.count))
                table.buffer.append(contentsOf: key)
                if let entry = items[String(decoding: key, as: UTF8.self)] {
                    table.entries.append(entry)
                }
            }
            return table
        }
    }

    /// 匹配主机名（已规范化）：返回命中的最小值（精确条目只在完全相等时命中）。
    public func match(_ host: String) -> Int? {
        guard !entries.isEmpty else { return nil }
        let labels = host.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        var key: [UInt8] = []
        key.reserveCapacity(host.utf8.count)
        var best: Int32?
        for (depth, label) in labels.reversed().enumerated() {
            if depth > 0 { key.append(UInt8(ascii: ".")) }
            key.append(contentsOf: label)
            guard let index = find(key) else { continue }
            let entry = entries[index]
            let isFull = depth == labels.count - 1
            if let suffix = entry.suffix { best = min(best ?? .max, suffix) }
            if isFull, let exact = entry.exact { best = min(best ?? .max, exact) }
        }
        return best.map(Int.init)
    }

    /// 是否命中（域名集用）。
    public func contains(_ host: String) -> Bool { match(host) != nil }

    private func find(_ key: [UInt8]) -> Int? {
        var low = 0
        var high = entries.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let start = Int(offsets[mid])
            let end = mid + 1 < offsets.count ? Int(offsets[mid + 1]) : buffer.count
            let order = compare(buffer[start..<end], key)
            if order == 0 { return mid }
            if order < 0 { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

    private func compare(_ lhs: ArraySlice<UInt8>, _ rhs: [UInt8]) -> Int {
        var i = lhs.startIndex
        var j = 0
        while i < lhs.endIndex, j < rhs.count {
            if lhs[i] != rhs[j] { return lhs[i] < rhs[j] ? -1 : 1 }
            i += 1
            j += 1
        }
        if i == lhs.endIndex, j == rhs.count { return 0 }
        return i == lhs.endIndex ? -1 : 1
    }

    static func reversed(_ domain: String) -> String {
        domain.split(separator: ".", omittingEmptySubsequences: false).reversed().joined(separator: ".")
    }
}
