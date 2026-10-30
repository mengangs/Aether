import AetherDNS
import AetherEngine
import AetherFoundation
import AetherProfile
import AetherRules
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// aether-bench：持续跟踪的基准（docs/13 §5.1、docs/05 §5）。以 Release 构建运行：
///
///     swift run -c release aether-bench [--baseline <上次结果.json>] [--output <本次结果.json>] [--quick]
///
/// 输出 Markdown 表格（写入 CI 摘要）；给出基线时附带变化率，退化超过 20% 时输出 GitHub Actions 警告。
/// 数据由固定种子生成，不读取网络或磁盘上的外部资源。

struct Generator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct Result: Codable {
    var name: String
    /// 主指标（越小越好）。
    var value: Double
    var unit: String
    var detail: String
}

let arguments = CommandLine.arguments
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}
let quick = arguments.contains("--quick")
let clock = ContinuousClock()

func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

func percentile(_ values: [Double], _ p: Double) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
}

var rng = Generator(state: 42)
let tlds = ["com", "net", "org", "example", "test"]
@MainActor func label(_ length: Int) -> String {
    let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789")
    return String((0..<length).map { _ in letters[Int(rng.next() % UInt64(letters.count))] })
}
@MainActor func domain() -> String {
    "\(label(Int(rng.next() % 8) + 3)).\(label(Int(rng.next() % 6) + 3)).\(tlds[Int(rng.next() % UInt64(tlds.count))])"
}

var results: [Result] = []

// MARK: 规则匹配：5,000 条普通规则 + 3 个各 5 万条的规则集（05 §5）

let ruleSetSize = quick ? 5_000 : 50_000
var ruleSets: [String: CompiledRuleSet] = [:]
var buildDurations: [Double] = []
for index in 0..<3 {
    var lines: [String] = []
    for _ in 0..<ruleSetSize {
        switch rng.next() % 10 {
        case 0..<6: lines.append("DOMAIN-SUFFIX,\(domain())")
        case 6..<8: lines.append("DOMAIN,\(domain())")
        case 8: lines.append("DOMAIN-KEYWORD,\(label(6))")
        default: lines.append("IP-CIDR,\(rng.next() % 223 + 1).\(rng.next() % 256).\(rng.next() % 256).0/24,no-resolve")
        }
    }
    let text = lines.joined(separator: "\n")
    let start = clock.now
    guard case .success(let parsed) = RuleSetParser.parse(text, name: "set\(index)") else { continue }
    ruleSets["https://bench.example/set\(index).list"] = CompiledRuleSet(parsed.rules)
    buildDurations.append(seconds(clock.now - start))
}
results.append(
    Result(
        name: "rule-set parse+compile (\(ruleSetSize) rules)",
        value: buildDurations.reduce(0, +) / Double(max(buildDurations.count, 1)) * 1000,
        unit: "ms", detail: "mean of \(buildDurations.count)"))

struct BenchResources: RuleResourceProvider {
    let sets: [String: CompiledRuleSet]
    func ruleSet(_ location: String) -> (any RuleSetMatching)? { sets[location] }
    func domainSet(_ location: String) -> ReversedDomainTable? { nil }
    var geoIP: (any IPMetadataLookup)? { nil }
    var ipASN: (any IPMetadataLookup)? { nil }
}

/// 生成 `[Rule]`：`mix` 为各类型的权重。
@MainActor func makeRules(count: Int, mix: [(String, Int)]) -> [RuleSpec] {
    let total = mix.reduce(0) { $0 + $1.1 }
    var lines = ["[Rule]"]
    for index in 0..<count {
        var pick = Int(rng.next() % UInt64(total))
        var kind = mix[0].0
        for (name, weight) in mix {
            if pick < weight {
                kind = name
                break
            }
            pick -= weight
        }
        let policy = "P\(index % 7)"
        switch kind {
        case "suffix": lines.append("DOMAIN-SUFFIX,\(domain()),\(policy)")
        case "domain": lines.append("DOMAIN,\(domain()),\(policy)")
        case "keyword": lines.append("DOMAIN-KEYWORD,\(label(5)),\(policy)")
        case "ip": lines.append("IP-CIDR,\(rng.next() % 223 + 1).\(rng.next() % 256).0.0/16,\(policy),no-resolve")
        case "ip6": lines.append("IP-CIDR6,2001:db8:\(String(rng.next() % 65536, radix: 16))::/48,\(policy),no-resolve")
        case "port": lines.append("DEST-PORT,\(rng.next() % 60000 + 1),\(policy)")
        default: lines.append("DOMAIN-WILDCARD,*.\(label(4)).\(tlds[0]),\(policy)")
        }
        if index % (count / 3) == count / 6 {
            lines.append("RULE-SET,https://bench.example/set\(index * 3 / count).list,R")
        }
    }
    lines.append("FINAL,DIRECT")
    return FragmentParser.parse(ProfileDocument.parse(lines.joined(separator: "\n"), fileName: "bench.conf").0).rules
}

let ruleCount = quick ? 500 : 5_000
let queries = (0..<(quick ? 2_000 : 20_000)).map { _ -> RouteContext in
    RouteContext(host: Hostname(domain()), hostSource: .request, destinationPort: 443)
}
/// 真实配置中的常见构成（docs/05 §5 的"普通规则"）与对规则引擎最不利的均匀混合。
let workloads: [(name: String, mix: [(String, Int)])] = [
    (
        "typical",
        [("suffix", 45), ("domain", 20), ("keyword", 10), ("ip", 15), ("ip6", 5), ("port", 3), ("wildcard", 2)]
    ),
    ("stress", [("suffix", 1), ("domain", 1), ("keyword", 1), ("ip", 1), ("port", 1), ("wildcard", 1)]),
]
var typicalProgram: RuleProgram?
for workload in workloads {
    let ruleSpecs = makeRules(count: ruleCount, mix: workload.mix)
    let compileStart = clock.now
    let program = RuleProgram.compile(ruleSpecs, resources: BenchResources(sets: ruleSets))
    if workload.name == "typical" {
        typicalProgram = program
        results.append(
            Result(
                name: "rule program compile (\(ruleSpecs.count) rules)",
                value: seconds(clock.now - compileStart) * 1000, unit: "ms",
                detail: ""))
    }
    var samples: [Double] = []
    samples.reserveCapacity(queries.count)
    var decided = 0
    for query in queries {
        let start = clock.now
        if case .decided = program.evaluate(query) { decided += 1 }
        samples.append(seconds(clock.now - start) * 1e6)
    }
    results.append(
        Result(
            name: "rule evaluate (\(workload.name)), uncached p99", value: percentile(samples, 0.99), unit: "µs",
            detail: "p50 \(String(format: "%.2f", percentile(samples, 0.5))) µs, \(queries.count) host-only queries"))
}

if let program = typicalProgram {
    let cache = RuleDecisionCache()
    let hot = Array(queries.prefix(1000))
    for query in hot { _ = program.evaluate(query, cache: cache) }
    var cached: [Double] = []
    for _ in 0..<5 {
        for query in hot {
            let start = clock.now
            _ = program.evaluate(query, cache: cache)
            cached.append(seconds(clock.now - start) * 1e6)
        }
    }
    results.append(
        Result(
            name: "rule evaluate, cached p50", value: percentile(cached, 0.5), unit: "µs",
            detail: "p99 \(String(format: "%.2f", percentile(cached, 0.99))) µs, hits \(cache.hits)"))
}

// MARK: 域名集：10 万条编译与缓存加载（05 §5）

let domainCount = quick ? 10_000 : 100_000
let domainText = (0..<domainCount).map { _ in (rng.next() % 2 == 0 ? "." : "") + domain() }.joined(separator: "\n")
let domainStart = clock.now
if case .success(let loaded) = DomainSetLoader.load(domainText) {
    results.append(
        Result(
            name: "domain set compile (\(domainCount))", value: seconds(clock.now - domainStart) * 1000, unit: "ms",
            detail: "\(loaded.table.estimatedBytes / 1024) KiB"))
    let hash = [UInt8](repeating: 1, count: 32)
    let bytes = RuleCompileCache.encode(loaded.table, sourceSHA256: hash)
    let loadStart = clock.now
    let decoded = RuleCompileCache.decodeDomainSet(bytes, sourceSHA256: hash)
    results.append(
        Result(
            name: "domain set cache load (\(domainCount))", value: seconds(clock.now - loadStart) * 1000, unit: "ms",
            detail: decoded == nil ? "FAILED" : "\(bytes.count / 1024) KiB on disk"))
}

// MARK: 配置解析：1 万行（04 §15.3）

var configLines = ["[General]", "loglevel = notice", "[Proxy]"]
let proxyCount = quick ? 100 : 1_000
for index in 0..<proxyCount {
    configLines.append(
        "N\(index) = ss, \(domain()), \(1000 + index), encrypt-method=aes-128-gcm, password=bench\(index)")
}
configLines.append("[Proxy Group]")
configLines.append("Proxy = select, " + (0..<min(proxyCount, 50)).map { "N\($0)" }.joined(separator: ", "))
configLines.append("[Rule]")
while configLines.count < (quick ? 1_000 : 10_000) - 1 {
    configLines.append("DOMAIN-SUFFIX,\(domain()),Proxy")
}
configLines.append("FINAL,DIRECT")
let configText = configLines.joined(separator: "\n")
var parseTimes: [Double] = []
for _ in 0..<5 {
    let start = clock.now
    let resolved = ProfileResolver.resolve(profileText: configText, fileName: "bench.conf")
    parseTimes.append(seconds(clock.now - start) * 1000)
    if resolved.diagnostics.containsErrors { print("::warning::bench profile has errors") }
}
results.append(
    Result(
        name: "profile parse+resolve (\(configLines.count) lines)", value: percentile(parseTimes, 0.5), unit: "ms",
        detail: "median of 5"))

// MARK: DNS 报文编解码（13 §5.1）

do {
    let question = DNSQuestion(name: DNSName("www.example.com")!, type: .a)
    var response = DNSMessage(header: DNSHeader(id: 1, isResponse: true, recursionAvailable: true))
    response.questions = [question]
    response.answers = [
        DNSResourceRecord(name: question.name, type: .cname, ttl: 300, data: .cname(DNSName("edge.example.net")!))
    ]
    for index in 0..<4 {
        response.answers.append(
            DNSResourceRecord(
                name: DNSName("edge.example.net")!, type: .a, ttl: 60, data: .a(IPv4Address(192, 0, 2, UInt8(index)))))
    }
    response.additionals = [DNSEDNS(udpPayloadSize: 1232).record]
    let iterations = quick ? 20_000 : 200_000
    let encodeStart = clock.now
    var bytes: [UInt8] = []
    for index in 0..<iterations {
        response.header.id = UInt16(truncatingIfNeeded: index)
        bytes = response.encode()
    }
    let encodeTime = seconds(clock.now - encodeStart) / Double(iterations) * 1e9
    let decodeStart = clock.now
    var decoded = 0
    for _ in 0..<iterations {
        if let message = try? DNSMessage.decode(bytes) { decoded += message.answers.count }
    }
    let decodeTime = seconds(clock.now - decodeStart) / Double(iterations) * 1e9
    results.append(
        Result(name: "dns encode (6 records)", value: encodeTime, unit: "ns", detail: "\(bytes.count) bytes"))
    results.append(
        Result(name: "dns decode (6 records)", value: decodeTime, unit: "ns", detail: "\(decoded / iterations) answers")
    )
}

// MARK: 输出

var baseline: [String: Double] = [:]
if let path = option("--baseline"), let data = FileManager.default.contents(atPath: path),
    let previous = try? JSONDecoder().decode([Result].self, from: data)
{
    baseline = Dictionary(previous.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first })
}
print("### Benchmarks\(quick ? " (quick)" : "")\n")
print("| Benchmark | Result | vs baseline | Detail |")
print("| --- | --- | --- | --- |")
for result in results {
    var delta = "—"
    if let previous = baseline[result.name], previous > 0 {
        let change = (result.value - previous) / previous * 100
        delta = String(format: "%+.1f%%", change)
        if change > 20 {
            delta += " ⚠️"
            FileHandle.standardError.write(
                Data("::warning::\(result.name) regressed by \(String(format: "%.1f", change))%\n".utf8))
        }
    }
    print("| \(result.name) | \(String(format: "%.2f", result.value)) \(result.unit) | \(delta) | \(result.detail) |")
}
if let path = option("--output") {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? encoder.encode(results) {
        _ = FileManager.default.createFile(atPath: path, contents: data)
    }
}
