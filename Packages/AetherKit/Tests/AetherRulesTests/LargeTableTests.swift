import AetherFoundation
import AetherTestSupport
import Testing

@testable import AetherRules

/// 大表（5,000 条）的偏移与条目数组一致，查找不越界。
@Test func largeTableCountsConsistent() {
    var rng = SplitMix64(seed: 42)
    let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    func label(_ n: Int) -> String { String((0..<n).map { _ in letters[Int(rng.next() % UInt64(letters.count))] }) }
    var builder = ReversedDomainTable.Builder()
    var count = 0
    for i in 0..<5000 {
        let domain = "\(label(Int(rng.next() % 8) + 3)).\(label(Int(rng.next() % 6) + 3)).com"
        builder.add(domain: domain, isSuffix: i % 2 == 0, value: i)
        count += 1
    }
    let table = builder.build()
    #expect(table.rawOffsets.count == table.rawEntries.count)
    #expect(table.rawOffsets.count == table.count)
    for _ in 0..<1000 {
        _ = table.match("\(label(5)).\(label(4)).com")
    }
}
