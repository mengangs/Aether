import AetherFoundation
import Foundation

/// 规则集与域名集的编译缓存格式（docs/05 §6.4），写入 `Resources/<资源哈希>.ruleset.bin`。
///
/// 文件头：4 字节魔数（规则集 `AERS`、域名集 `AEDS`）、UInt16 格式版本、32 字节源内容 SHA-256。
/// 任何一项不符、或内容越界与不一致时解码返回 nil，调用方丢弃缓存并从源文件重建。数据结构变化时递增格式版本。
public enum RuleCompileCache {
    public static let formatVersion: UInt16 = 1
    static let ruleSetMagic: [UInt8] = Array("AERS".utf8)
    static let domainSetMagic: [UInt8] = Array("AEDS".utf8)

    // MARK: 规则集

    public static func encode(_ set: CompiledRuleSet, sourceSHA256: [UInt8]) -> [UInt8] {
        var writer = header(ruleSetMagic, sourceSHA256)
        writer.write(UInt32(set.ruleCount))
        writer.write(UInt8(set.hasIPRules ? 1 : 0))
        writer.write(UInt8(set.hasResolvableIPRules ? 1 : 0))
        let exact = set.domains.exact.sorted { $0.key < $1.key }
        writer.write(UInt32(exact.count))
        for (host, index) in exact {
            writer.write(host)
            writer.write(Int32(clamping: index))
        }
        writeDomainTable(set.domains.suffix, into: &writer)
        writer.write(UInt32(set.domains.keywords.keywords.count))
        for (keyword, value) in set.domains.keywords.keywords {
            writer.write(keyword)
            writer.write(Int32(clamping: value))
        }
        writer.write(UInt32(set.domains.wildcards.count))
        for (pattern, index) in set.domains.wildcards {
            writer.write(pattern)
            writer.write(Int32(clamping: index))
        }
        let v4 = set.ips.v4.segments
        writer.write(UInt32(v4.count))
        for segment in v4 {
            writer.write(segment.start)
            writer.write(segment.end)
            writer.write(segment.value)
        }
        let v6 = set.ips.v6.segments
        writer.write(UInt32(v6.count))
        for segment in v6 {
            writer.write(segment.start.high)
            writer.write(segment.start.low)
            writer.write(segment.end.high)
            writer.write(segment.end.low)
            writer.write(segment.value)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // 编码结果确定，同一规则集总是得到相同的缓存字节
        let others = (try? encoder.encode(set.otherSpecs)).map { Array($0) } ?? Array("[]".utf8)
        writer.write(others)
        return writer.bytes
    }

    public static func decodeRuleSet(
        _ bytes: [UInt8], sourceSHA256: [UInt8], resources: some RuleResourceProvider = EmptyRuleResources(),
        platform: PlatformCapabilities = .iOS
    ) -> CompiledRuleSet? {
        var reader = BinaryReader(bytes)
        guard checkHeader(&reader, ruleSetMagic, sourceSHA256),
            let ruleCount = reader.read(UInt32.self), Int(ruleCount) <= ResourceLimits.maxEntries,
            let hasIP = reader.readByte(), let resolvable = reader.readByte(),
            let exactCount = reader.read(UInt32.self), Int(exactCount) <= ResourceLimits.maxEntries
        else { return nil }
        var exact: [String: Int] = [:]
        for _ in 0..<exactCount {
            guard let host = reader.readString(limit: 1024), let index = reader.read(Int32.self) else { return nil }
            exact[host] = Int(index)
        }
        guard let suffix = readDomainTable(&reader),
            let keywordCount = reader.read(UInt32.self), Int(keywordCount) <= ResourceLimits.maxEntries
        else { return nil }
        var keywords: [(keyword: String, value: Int)] = []
        for _ in 0..<keywordCount {
            guard let keyword = reader.readString(limit: 1024), let value = reader.read(Int32.self) else { return nil }
            keywords.append((keyword, Int(value)))
        }
        guard let wildcardCount = reader.read(UInt32.self), Int(wildcardCount) <= ResourceLimits.maxEntries else {
            return nil
        }
        var wildcards: [(pattern: String, index: Int)] = []
        for _ in 0..<wildcardCount {
            guard let pattern = reader.readString(limit: 1024), let index = reader.read(Int32.self) else { return nil }
            wildcards.append((pattern, Int(index)))
        }
        guard let v4Count = reader.read(UInt32.self), Int(v4Count) <= 2 * ResourceLimits.maxEntries + 1 else {
            return nil
        }
        var v4: ([UInt32], [UInt32], [Int32]) = ([], [], [])
        for _ in 0..<v4Count {
            guard let start = reader.read(UInt32.self), let end = reader.read(UInt32.self),
                let value = reader.read(Int32.self)
            else {
                return nil
            }
            v4.0.append(start)
            v4.1.append(end)
            v4.2.append(value)
        }
        guard let v6Count = reader.read(UInt32.self), Int(v6Count) <= 2 * ResourceLimits.maxEntries + 1 else {
            return nil
        }
        var v6: ([UInt128Value], [UInt128Value], [Int32]) = ([], [], [])
        for _ in 0..<v6Count {
            guard let sh = reader.read(UInt64.self), let sl = reader.read(UInt64.self),
                let eh = reader.read(UInt64.self),
                let el = reader.read(UInt64.self), let value = reader.read(Int32.self)
            else { return nil }
            v6.0.append(UInt128Value(high: sh, low: sl))
            v6.1.append(UInt128Value(high: eh, low: el))
            v6.2.append(value)
        }
        guard let othersData = reader.readBytes(limit: ResourceLimits.maxBytes), reader.isAtEnd,
            let otherSpecs = try? JSONDecoder().decode([RuleSpec].self, from: Data(othersData)),
            let v4Table = IntervalTable(starts: v4.0, ends: v4.1, values: v4.2),
            let v6Table = IntervalTable(starts: v6.0, ends: v6.1, values: v6.2)
        else { return nil }
        return CompiledRuleSet(
            domains: DomainIndex(
                exact: exact, suffix: suffix, keywords: KeywordMatcher(keywords), wildcards: wildcards),
            ips: IPIndex(v4: v4Table, v6: v6Table), otherSpecs: otherSpecs, hasIPRules: hasIP == 1,
            hasResolvableIPRules: resolvable == 1, ruleCount: Int(ruleCount), resources: resources, platform: platform)
    }

    // MARK: 域名集

    public static func encode(_ table: ReversedDomainTable, sourceSHA256: [UInt8]) -> [UInt8] {
        var writer = header(domainSetMagic, sourceSHA256)
        writeDomainTable(table, into: &writer)
        return writer.bytes
    }

    public static func decodeDomainSet(_ bytes: [UInt8], sourceSHA256: [UInt8]) -> ReversedDomainTable? {
        var reader = BinaryReader(bytes)
        guard checkHeader(&reader, domainSetMagic, sourceSHA256), let table = readDomainTable(&reader), reader.isAtEnd
        else {
            return nil
        }
        return table
    }

    // MARK: 内部

    static func header(_ magic: [UInt8], _ hash: [UInt8]) -> BinaryWriter {
        var writer = BinaryWriter()
        writer.append(raw: magic)
        writer.write(formatVersion)
        writer.append(raw: Array(hash.prefix(32)) + [UInt8](repeating: 0, count: max(0, 32 - hash.count)))
        return writer
    }

    static func checkHeader(_ reader: inout BinaryReader, _ magic: [UInt8], _ hash: [UInt8]) -> Bool {
        guard hash.count == 32, reader.readRaw(count: 4) == magic, reader.read(UInt16.self) == formatVersion,
            reader.readRaw(count: 32) == hash
        else { return false }
        return true
    }

    static func writeDomainTable(_ table: ReversedDomainTable, into writer: inout BinaryWriter) {
        writer.write(table.rawBuffer)
        writer.write(UInt32(table.rawOffsets.count))
        for (offset, entry) in zip(table.rawOffsets, table.rawEntries) {
            writer.write(offset)
            writer.write(entry.exact ?? -1)
            writer.write(entry.suffix ?? -1)
        }
    }

    static func readDomainTable(_ reader: inout BinaryReader) -> ReversedDomainTable? {
        guard let buffer = reader.readBytes(limit: ResourceLimits.maxBytes), let count = reader.read(UInt32.self),
            Int(count) <= ResourceLimits.maxEntries
        else { return nil }
        var offsets: [UInt32] = []
        var entries: [ReversedDomainTable.Entry] = []
        offsets.reserveCapacity(Int(count))
        entries.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let offset = reader.read(UInt32.self), let exact = reader.read(Int32.self),
                let suffix = reader.read(Int32.self)
            else {
                return nil
            }
            offsets.append(offset)
            entries.append(ReversedDomainTable.Entry(exact: exact < 0 ? nil : exact, suffix: suffix < 0 ? nil : suffix))
        }
        return ReversedDomainTable(buffer: buffer, offsets: offsets, entries: entries)
    }
}
