import AetherTestSupport
import Foundation
import Testing

@testable import AetherFoundation

struct PunycodeTests {
    struct Sample: Decodable, Sendable, CustomTestStringConvertible {
        let description: String
        let decoded: String
        let encoded: String
        var testDescription: String { description }
    }

    struct File: Decodable {
        let cases: [Sample]
    }

    static let samples: [Sample] = {
        (try? JSONDecoder().decode(File.self, from: Fixtures.data("vectors/punycode/samples.json")))?.cases ?? []
    }()

    @Test func samplesLoaded() {
        #expect(Self.samples.count == 24)
    }

    @Test(arguments: samples)
    func encodes(_ sample: Sample) {
        #expect(Punycode.encode(sample.decoded) == sample.encoded)
    }

    @Test(arguments: samples)
    func decodes(_ sample: Sample) {
        #expect(Punycode.decode(sample.encoded) == sample.decoded)
    }

    @Test func decodesMixedCaseAnnotation() {
        // RFC 3492 §7.1 (I) 原文带大小写标注。
        #expect(
            Punycode.decode("b1abfaaepdrnnbgefbaDotcwatmq2g4l") == Punycode.decode("b1abfaaepdrnnbgefbadotcwatmq2g4l"))
    }

    @Test(arguments: ["99999999999999999999999", "ü", "a-!!", "zzzzzzzzzzzzzzzzzzzzzzzzzz9"])
    func rejectsInvalidInput(_ input: String) {
        #expect(Punycode.decode(input) == nil)
    }
}

struct IPAddressTests {
    @Test(arguments: ["0.0.0.0", "192.0.2.1", "255.255.255.255", "198.18.0.1"])
    func ipv4RoundTrips(_ text: String) throws {
        let address = try #require(IPAddress(text))
        #expect(address.description == text)
        #expect(address.isIPv4)
        #expect(IPAddress(bytes: address.bytes) == address)
    }

    @Test(arguments: ["256.0.0.1", "1.2.3", "1.2.3.4.5", "01.2.3.4", "1.2.3.", " 1.2.3.4", "1..2.3", "a.b.c.d", ""])
    func rejectsInvalidIPv4(_ text: String) {
        #expect(IPv4Address(text) == nil)
    }

    @Test(arguments: [
        ("2001:db8::1", "2001:db8::1"),
        ("2001:0DB8:0000:0000:0000:0000:0000:0001", "2001:db8::1"),
        ("::", "::"),
        ("::1", "::1"),
        ("1::", "1::"),
        ("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"),
        ("2001:db8:0:1:1:1:1:1", "2001:db8:0:1:1:1:1:1"),
        ("fe80::1:2", "fe80::1:2"),
        ("::ffff:192.0.2.128", "::ffff:192.0.2.128"),
        ("64:ff9b::192.0.2.33", "64:ff9b::c000:221"),
    ])
    func ipv6CanonicalForm(_ input: String, _ canonical: String) throws {
        let address = try #require(IPAddress(input))
        #expect(address.description == canonical)
        #expect(IPAddress(bytes: address.bytes) == address)
    }

    @Test(arguments: [
        ":::", "1:2:3:4:5:6:7:8:9", "1::2::3", "12345::", "g::1", "1:2:3:4:5:6:7", ":1:2:3:4:5:6:7", "[::1]", "::1%en0",
        "::ffff:300.1.1.1",
    ])
    func rejectsInvalidIPv6(_ text: String) {
        #expect(IPv6Address(text) == nil)
    }

    @Test func mappedAddressUnmapsToIPv4() throws {
        let mapped = try #require(IPAddress("::ffff:192.0.2.1"))
        #expect(mapped.unmappedIPv4 == IPAddress("192.0.2.1"))
        #expect(IPv6Address(mapping: IPv4Address(192, 0, 2, 1)).description == "::ffff:192.0.2.1")
    }

    @Test func ordering() throws {
        let sorted = try ["2001:db8::1", "192.0.2.2", "::1", "192.0.2.1"].map { try #require(IPAddress($0)) }.sorted()
        #expect(sorted.map(\.description) == ["192.0.2.1", "192.0.2.2", "::1", "2001:db8::1"])
    }
}

struct CIDRTests {
    @Test func normalizesHostBits() throws {
        let cidr = try #require(CIDR("192.0.2.77/24"))
        #expect(cidr.description == "192.0.2.0/24")
        #expect(cidr.ipv4SubnetMask?.description == "255.255.255.0")
        #expect(CIDR("198.18.0.0/15")?.ipv4SubnetMask?.description == "255.254.0.0")
    }

    @Test func ipv4Boundaries() throws {
        let cidr = try #require(CIDR("198.51.100.0/24"))
        #expect(cidr.contains(try #require(IPAddress("198.51.100.0"))))
        #expect(cidr.contains(try #require(IPAddress("198.51.100.255"))))
        #expect(!cidr.contains(try #require(IPAddress("198.51.99.255"))))
        #expect(!cidr.contains(try #require(IPAddress("198.51.101.0"))))
        #expect(cidr.contains(try #require(IPAddress("::ffff:198.51.100.9"))))
        #expect(!cidr.contains(try #require(IPAddress("2001:db8::1"))))
        #expect(cidr.range.lowerBound.description == "198.51.100.0")
        #expect(cidr.range.upperBound.description == "198.51.100.255")
    }

    @Test func ipv6Boundaries() throws {
        let cidr = try #require(CIDR("2001:db8::/32"))
        #expect(cidr.contains(try #require(IPAddress("2001:db8::"))))
        #expect(cidr.contains(try #require(IPAddress("2001:db8:ffff:ffff:ffff:ffff:ffff:ffff"))))
        #expect(!cidr.contains(try #require(IPAddress("2001:db9::"))))
        #expect(!cidr.contains(try #require(IPAddress("2001:db7:ffff:ffff:ffff:ffff:ffff:ffff"))))
        let wide = try #require(CIDR("fc00::/7"))
        #expect(wide.contains(try #require(IPAddress("fdff::1"))))
        #expect(!wide.contains(try #require(IPAddress("fe00::1"))))
        let long = try #require(CIDR("2001:db8::1:0/112"))
        #expect(long.contains(try #require(IPAddress("2001:db8::1:ffff"))))
        #expect(!long.contains(try #require(IPAddress("2001:db8::2:0"))))
    }

    @Test(arguments: ["0.0.0.0/0", "::/0", "192.0.2.1", "2001:db8::1"])
    func edgePrefixes(_ text: String) throws {
        let cidr = try #require(CIDR(text))
        #expect(cidr.contains(cidr.network))
    }

    @Test(arguments: [
        "192.0.2.0/33", "2001:db8::/129", "192.0.2.0/", "192.0.2.0/-1", "192.0.2.0/a", "x/8", "192.0.2.0/0008",
    ])
    func rejectsInvalid(_ text: String) {
        #expect(CIDR(text) == nil)
    }
}

struct HostnameTests {
    @Test func normalizesCaseAndTrailingDot() throws {
        let host = try #require(Hostname("WWW.Example.COM."))
        #expect(host.value == "www.example.com")
        #expect(host.original == "WWW.Example.COM.")
        #expect(host == Hostname("www.example.com"))
    }

    @Test func unicodeAndPunycodeAreEqual() throws {
        let unicode = try #require(Hostname("例子.测试"))
        let ascii = try #require(Hostname("xn--fsqu00a.xn--0zwm56d"))
        #expect(unicode == ascii)
        #expect(unicode.value == "xn--fsqu00a.xn--0zwm56d")
        #expect(ascii.unicodeDisplay == "例子.测试")
        #expect(try #require(Hostname("BÜCHER.example")).value == "xn--bcher-kva.example")
    }

    @Test(arguments: ["", ".", "a..b", "a b.com", "tab\t.com", ".leading.com", String(repeating: "a.", count: 130)])
    func rejectsInvalid(_ text: String) {
        #expect(Hostname(text) == nil)
    }

    @Test func suffixSemantics() throws {
        let suffix = try #require(Hostname("example.com"))
        #expect(try #require(Hostname("a.example.com")).hasDomainSuffix(suffix))
        #expect(try #require(Hostname("example.com")).hasDomainSuffix(suffix))
        #expect(!(try #require(Hostname("notexample.com")).hasDomainSuffix(suffix)))
    }

    @Test func classification() throws {
        #expect(try #require(Hostname("router")).isSimple)
        #expect(try #require(Hostname("192.0.2.1")).isIPAddress)
        #expect(!(try #require(Hostname("example.com")).isSimple))
    }

    @Test func endpointDescription() throws {
        #expect(Endpoint(host: "example.com", port: 443)?.description == "example.com:443")
        #expect(Endpoint(host: "2001:db8::1", port: 53)?.description == "[2001:db8::1]:53")
        #expect(Endpoint(host: "192.0.2.1", port: 80)?.host == .address(try #require(IPAddress("192.0.2.1"))))
    }
}

struct LRUCacheTests {
    @Test func evictsLeastRecentlyUsed() {
        var cache = LRUCache<String, Int>(capacity: 2)
        cache.set("a", 1)
        cache.set("b", 2)
        #expect(cache.get("a") == 1)
        let evicted = cache.set("c", 3)
        #expect(evicted?.key == "b")
        #expect(cache.get("b") == nil)
        #expect(cache.keysByRecency == ["c", "a"])
        #expect(cache.count == 2)
    }

    @Test func updateMovesToFront() {
        var cache = LRUCache<Int, Int>(capacity: 3)
        for i in 0..<3 { cache.set(i, i) }
        cache.set(0, 10)
        cache.set(3, 3)
        #expect(cache.peek(1) == nil)
        #expect(cache.peek(0) == 10)
    }

    @Test func removeTrimAndReuse() {
        var cache = LRUCache<Int, Int>(capacity: 100)
        for i in 0..<100 { cache.set(i, i) }
        #expect(cache.remove(50) == 50)
        cache.trim(to: 10)
        #expect(cache.count == 10)
        #expect(cache.keysByRecency == Array((90..<100).reversed()))
        for i in 200..<300 { cache.set(i, i) }
        #expect(cache.count == 100)
        cache.removeAll()
        #expect(cache.count == 0)
        cache.set(1, 1)
        #expect(cache.get(1) == 1)
    }

    @Test func randomizedAgainstReferenceModel() {
        var rng = SplitMix64(seed: 42)
        var cache = LRUCache<Int, Int>(capacity: 16)
        var model: [(Int, Int)] = []  // 最近使用在前
        for step in 0..<5000 {
            let key = Int(rng.next() % 40)
            if rng.next() % 3 == 0 {
                let expected = model.first { $0.0 == key }?.1
                #expect(cache.get(key) == expected, "step \(step)")
                if let i = model.firstIndex(where: { $0.0 == key }) {
                    model.insert(model.remove(at: i), at: 0)
                }
            } else {
                cache.set(key, step)
                model.removeAll { $0.0 == key }
                model.insert((key, step), at: 0)
                if model.count > 16 { model.removeLast() }
            }
        }
        #expect(cache.keysByRecency == model.map(\.0))
    }
}

@Test func bytesHexAndBigEndian() {
    #expect(Bytes.hex([0x00, 0xAB, 0xFF]) == "00abff")
    #expect(Bytes.fromHex("00:AB:ff") == [0x00, 0xAB, 0xFF])
    #expect(Bytes.fromHex("abc") == nil)
    #expect(Bytes.fromHex("zz") == nil)
    var buffer: [UInt8] = []
    Bytes.appendBigEndian(UInt16(0x1234), to: &buffer)
    Bytes.appendBigEndian(UInt32(0xDEAD_BEEF), to: &buffer)
    #expect(buffer == [0x12, 0x34, 0xDE, 0xAD, 0xBE, 0xEF])
    #expect(Bytes.readBigEndian(UInt32.self, from: buffer, at: 2) == 0xDEAD_BEEF)
    #expect(Bytes.readBigEndian(UInt32.self, from: buffer, at: 3) == nil)
}
