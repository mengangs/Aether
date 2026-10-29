import AetherFoundation
import AetherTestSupport
import Testing

@testable import AetherRules

struct ReversedDomainTableTests {
    @Test func exactAndSuffix() {
        var builder = ReversedDomainTable.Builder()
        builder.add(domain: "example.com", isSuffix: true, value: 5)
        builder.add(domain: "example.com", isSuffix: false, value: 2)
        builder.add(domain: "a.example.com", isSuffix: false, value: 9)
        builder.add(domain: "net", isSuffix: true, value: 7)
        let table = builder.build()
        #expect(table.count == 3)
        #expect(table.match("example.com") == 2)
        #expect(table.match("a.example.com") == 5)
        #expect(table.match("b.a.example.com") == 5)
        #expect(table.match("notexample.com") == nil)
        #expect(table.match("x.example.net") == 7)
        #expect(table.match("com") == nil)
    }

    @Test func randomizedAgainstNaive() {
        var rng = SplitMix64(seed: 3)
        let labels = ["a", "b", "example", "com", "net", "x"]
        func randomDomain() -> String {
            (0...Int(rng.next() % 3)).map { _ in labels[Int(rng.next() % UInt64(labels.count))] }.joined(separator: ".")
        }
        var builder = ReversedDomainTable.Builder()
        var entries: [(String, Bool, Int)] = []
        for value in 0..<200 {
            let domain = randomDomain()
            let suffix = rng.next() % 2 == 0
            builder.add(domain: domain, isSuffix: suffix, value: value)
            entries.append((domain, suffix, value))
        }
        let table = builder.build()
        for _ in 0..<500 {
            let host = randomDomain()
            let expected = entries.filter { domain, suffix, _ in
                host == domain || (suffix && host.hasSuffix("." + domain))
            }.map(\.2).min()
            #expect(table.match(host) == expected, "\(host)")
        }
    }
}

struct KeywordAndWildcardTests {
    @Test func ahoCorasickMatchesLinear() {
        var rng = SplitMix64(seed: 11)
        let alphabet = Array("abcde.")
        func word(_ length: Int) -> String {
            String((0..<length).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] })
        }
        var keywords: [(keyword: String, value: Int)] = []
        for _ in 0..<80 {
            keywords.append((keyword: word(Int(rng.next() % 4) + 1), value: Int(rng.next() % 1000)))
        }
        let automaton = KeywordMatcher(keywords)
        for _ in 0..<1000 {
            let text = word(Int(rng.next() % 20))
            let expected = keywords.filter { text.contains($0.keyword) }.map { $0.value }.min()
            #expect(automaton.match(text) == expected, "\(text)")
        }
        #expect(KeywordMatcher(Array(keywords.prefix(10))).count == 10)
    }

    @Test(arguments: [
        ("*.example.com", "a.example.com", true), ("*.example.com", "example.com", false), ("*", "", true),
        ("cdn?.example.net", "cdn1.example.net", true), ("cdn?.example.net", "cdn12.example.net", false),
        ("a*b*c", "aXXbYYc", true), ("a*b*c", "aXXbYY", false), ("*.EXAMPLE.com", "x.example.COM", true),
        ("**a", "bba", true), ("?", "", false), ("ExampleApp*", "ExampleApp/2.1 CFNetwork", true),
    ])
    func wildcard(_ pattern: String, _ text: String, _ expected: Bool) {
        #expect(Wildcard.matches(pattern, text) == expected)
    }
}

struct IntervalTableTests {
    @Test func overlappingIntervalsKeepMinimumValue() {
        let intervals: [(lower: UInt32, upper: UInt32, value: Int)] = [
            (10, 20, 5), (15, 30, 2), (0, 100, 9), (40, 40, 1), (UInt32.max - 1, UInt32.max, 3),
        ]
        let table = IntervalTable(intervals)
        #expect(table.lookup(9) == 9)
        #expect(table.lookup(10) == 5)
        #expect(table.lookup(15) == 2)
        #expect(table.lookup(30) == 2)
        #expect(table.lookup(31) == 9)
        #expect(table.lookup(40) == 1)
        #expect(table.lookup(100) == 9)
        #expect(table.lookup(101) == nil)
        #expect(table.lookup(UInt32.max) == 3)
    }

    @Test func randomizedAgainstNaive() {
        var rng = SplitMix64(seed: 21)
        for _ in 0..<50 {
            let intervals = (0..<Int(rng.next() % 40)).map { _ -> (lower: UInt32, upper: UInt32, value: Int) in
                let a = UInt32(rng.next() % 200)
                let b = UInt32(rng.next() % 200)
                return (min(a, b), max(a, b), Int(rng.next() % 50))
            }
            let table = IntervalTable(intervals)
            for x in UInt32(0)...210 {
                let expected = intervals.filter { $0.lower <= x && x <= $0.upper }.map(\.value).min()
                #expect(table.lookup(x) == expected)
            }
        }
    }

    @Test func ipv6Bounds() {
        let max = UInt128Value(high: .max, low: .max)
        let table = IntervalTable<UInt128Value>([
            (UInt128Value(high: 0, low: .max), UInt128Value(high: 1, low: 0), 1),
            (UInt128Value(high: 5, low: 0), max, 2),
        ])
        #expect(table.lookup(UInt128Value(high: 0, low: .max)) == 1)
        #expect(table.lookup(UInt128Value(high: 1, low: 0)) == 1)
        #expect(table.lookup(UInt128Value(high: 1, low: 1)) == nil)
        #expect(table.lookup(max) == 2)
    }
}
