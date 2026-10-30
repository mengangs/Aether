import AetherFoundation
import AetherTestSupport
import Testing

@testable import AetherDNS

private func name(_ text: String) -> DNSName {
    DNSName(text)!
}

private func sampleResponse() -> DNSMessage {
    let question = DNSQuestion(name: name("www.example.com"), type: .a)
    var header = DNSHeader(id: 0x1234, isResponse: true, recursionAvailable: true)
    header.authenticData = true
    return DNSMessage(
        header: header,
        questions: [question],
        answers: [
            DNSResourceRecord(
                name: name("www.example.com"), type: .cname, ttl: 300, data: .cname(name("edge.example.net"))),
            DNSResourceRecord(name: name("edge.example.net"), type: .a, ttl: 60, data: .a(IPv4Address(192, 0, 2, 10))),
            DNSResourceRecord(
                name: name("edge.example.net"), type: .aaaa, ttl: 60, data: .aaaa(IPv6Address("2001:db8::10")!)),
            DNSResourceRecord(
                name: name("www.example.com"), type: .https, ttl: 120,
                data: .serviceBinding(
                    DNSServiceBinding(
                        priority: 1, target: .root,
                        parameters: [
                            .init(key: 1, value: Array("\u{2}h2".utf8)), .init(key: 4, value: [192, 0, 2, 10]),
                        ]
                    ))),
            DNSResourceRecord(
                name: name("www.example.com"), type: .txt, ttl: 30, data: .opaque([5] + Array("hello".utf8))),
        ],
        authorities: [
            DNSResourceRecord(
                name: name("example.com"), type: .soa, ttl: 900,
                data: .soa(
                    DNSSOA(
                        primaryServer: name("ns1.example.com"), responsibleMailbox: name("hostmaster.example.com"),
                        serial: 2_026_103_001, refresh: 7200, retry: 900, expire: 1_209_600, minimum: 120)))
        ],
        additionals: [DNSEDNS(udpPayloadSize: 1232, options: [0, 10, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8]).record]
    )
}

@Suite("DNS message codec")
struct DNSMessageTests {
    @Test("Encode and decode round-trip every structured type and EDNS options")
    func roundTrip() throws {
        let message = sampleResponse()
        let bytes = message.encode()
        let decoded = try DNSMessage.decode(bytes)
        #expect(decoded == message)
        #expect(decoded.edns?.udpPayloadSize == 1232)
        #expect(decoded.edns?.options == [0, 10, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    @Test("Names are compressed against earlier occurrences")
    func compression() {
        var single = DNSMessage(header: DNSHeader(id: 1))
        single.questions = [DNSQuestion(name: name("www.example.com"), type: .a)]
        var twice = single
        twice.answers = [DNSResourceRecord(name: name("www.example.com"), type: .a, ttl: 1, data: .a(IPv4Address(1)))]
        // 第二次出现只占 2 字节指针：12 头 + 17 名 + 4 + (2 + 10 + 4) = 49
        #expect(single.encode().count == 12 + 17 + 4)
        #expect(twice.encode().count == 12 + 17 + 4 + 2 + 10 + 4)
    }

    @Test("Handcrafted compressed message decodes")
    func handcraftedPointer() throws {
        var bytes: [UInt8] = [0xAB, 0xCD, 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0]
        bytes += [7] + Array("example".utf8) + [3] + Array("com".utf8) + [0, 0, 1, 0, 1]
        bytes += [0xC0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1]
        let message = try DNSMessage.decode(bytes)
        #expect(message.header.id == 0xABCD)
        #expect(message.answers.first?.name.text == "example.com")
        #expect(message.answers.first?.address == IPAddress("192.0.2.1"))
    }

    @Test("Pointer loops and forward pointers are rejected")
    func pointerLoops() {
        // 问题名是指向自身的指针。
        let selfLoop: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 12, 0, 1, 0, 1]
        #expect(throws: DNSDecodeError.badPointer) { try DNSMessage.decode(selfLoop) }
        // 指向后方（尚未读到的位置）。
        let forward: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0xC0, 20, 0, 1, 0, 1, 1, 0x61, 0]
        #expect(throws: DNSDecodeError.badPointer) { try DNSMessage.decode(forward) }
        // 两个名称互相指向：第二个名称指向第一个名称中的指针，第一个指针再指向第二个。
        var mutual: [UInt8] = [0, 1, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0]
        mutual += [1, 0x61, 0xC0, 18, 0, 1, 0, 1]  // offset 12: "a" + ptr→18
        mutual += [0xC0, 12, 0, 1, 0, 1]  // offset 18: ptr→12
        #expect(throws: DNSDecodeError.self) { try DNSMessage.decode(mutual) }
    }

    @Test("Every truncated prefix throws instead of crashing")
    func truncatedPrefixes() {
        let bytes = sampleResponse().encode()
        for length in 0..<bytes.count {
            #expect(throws: DNSDecodeError.self) { try DNSMessage.decode(Array(bytes.prefix(length))) }
        }
    }

    @Test("Overlong labels and names are rejected")
    func limits() {
        #expect(DNSName(String(repeating: "a", count: 64) + ".com") == nil)
        #expect(DNSName(String(repeating: "a", count: 63) + ".com") != nil)
        let longName = Array(repeating: String(repeating: "b", count: 63), count: 4).joined(separator: ".")
        #expect(DNSName(longName) == nil)
        // 线上格式：5 个 63 字节的标签超过 255 字节。
        var bytes: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for _ in 0..<5 { bytes += [63] + Array(repeating: 0x61, count: 63) }
        bytes += [0, 0, 1, 0, 1]
        #expect(throws: DNSDecodeError.nameTooLong) { try DNSMessage.decode(bytes) }
        // 保留的标签类型 0x40。
        let extended: [UInt8] = [0, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x41, 0, 0, 1, 0, 1]
        #expect(throws: DNSDecodeError.unsupportedLabelType) { try DNSMessage.decode(extended) }
    }

    @Test("Seeded mutations never crash the decoder")
    func fuzz() {
        var generator = SplitMix64(seed: 0xD15)
        let seeds = [sampleResponse().encode(), DNSMessage.response(to: sampleResponse(), code: .nameError).encode()]
        var decoded = 0
        for iteration in 0..<20_000 {
            var bytes = seeds[iteration % seeds.count]
            let mutations = 1 + Int(generator.next() % 6)
            for _ in 0..<mutations {
                switch generator.next() % 4 {
                case 0 where !bytes.isEmpty:
                    bytes[Int(generator.next() % UInt64(bytes.count))] = UInt8(truncatingIfNeeded: generator.next())
                case 1 where !bytes.isEmpty:
                    bytes.remove(at: Int(generator.next() % UInt64(bytes.count)))
                case 2:
                    bytes.insert(
                        UInt8(truncatingIfNeeded: generator.next()), at: Int(generator.next() % UInt64(bytes.count + 1))
                    )
                default:
                    bytes = Array(bytes.prefix(Int(generator.next() % UInt64(bytes.count + 1))))
                }
            }
            if let message = try? DNSMessage.decode(bytes) {
                decoded += 1
                _ = message.encode()
                _ = try? DNSWire.scan(bytes)
            }
        }
        #expect(decoded > 0)
    }

    @Test("Record types parse by name and print by name")
    func typeNames() {
        #expect(DNSRecordType(name: "aaaa") == .aaaa)
        #expect(DNSRecordType(name: "TYPE99")?.rawValue == 99)
        #expect(DNSRecordType(rawValue: 99).description == "TYPE99")
        #expect(DNSRecordType.https.description == "HTTPS")
        #expect(DNSResponseCode.nameError.description == "NXDOMAIN")
    }
}

@Suite("DNS wire helpers")
struct DNSWireTests {
    @Test("ID patching, TTL ageing and question case copying")
    func patching() throws {
        var bytes = sampleResponse().encode()
        let scanned = try DNSWire.scan(bytes)
        // OPT 记录的 TTL 字段不计入。
        #expect(scanned.ttlFields.count == 6)
        #expect(scanned.minimumAnswerTTL == 30)
        #expect(scanned.negativeTTL == 120)
        #expect(scanned.addresses == [IPAddress("192.0.2.10")!, IPAddress("2001:db8::10")!])

        DNSWire.setID(0xBEEF, in: &bytes)
        DNSWire.ageTTLs(in: &bytes, fields: scanned.ttlFields, elapsedSeconds: 50)
        let aged = try DNSMessage.decode(bytes)
        #expect(aged.header.id == 0xBEEF)
        #expect(aged.answers.map(\.ttl) == [250, 10, 10, 70, 1])
        #expect(aged.authorities.first?.ttl == 850)
        #expect(aged.edns?.udpPayloadSize == 1232)

        var query = DNSMessage(header: DNSHeader(id: 7))
        query.questions = [DNSQuestion(name: name("WWW.Example.COM"), type: .a)]
        DNSWire.copyQuestionName(from: query.encode(), into: &bytes)
        #expect(try DNSMessage.decode(bytes).questions.first?.name.text == "WWW.Example.COM")
    }

    @Test("UDP size limit follows EDNS and truncation sets TC")
    func truncation() throws {
        var query = DNSMessage(header: DNSHeader(id: 9))
        query.questions = [DNSQuestion(name: name("big.example.com"), type: .txt)]
        #expect(DNSWire.udpLimit(for: query) == 512)
        var withEDNS = query
        withEDNS.additionals = [DNSEDNS(udpPayloadSize: 4096).record]
        #expect(DNSWire.udpLimit(for: withEDNS) == 1232)
        withEDNS.additionals = [DNSEDNS(udpPayloadSize: 100).record]
        #expect(DNSWire.udpLimit(for: withEDNS) == 512)

        let records = (0..<40).map { index in
            DNSResourceRecord(
                name: name("big.example.com"), type: .txt, ttl: 60,
                data: .opaque([20] + Array(repeating: 0x41, count: 20)))
        }
        let big = DNSMessage.response(to: query, answers: records).encode()
        #expect(big.count > 512)
        let truncated = DNSWire.truncateIfNeeded(big, query: query, limit: 512)
        let decoded = try DNSMessage.decode(truncated)
        #expect(decoded.header.isTruncated)
        #expect(decoded.answers.isEmpty)
        #expect(decoded.header.id == 9)
        #expect(DNSWire.truncateIfNeeded(big, query: query, limit: 65535) == big)
    }

    @Test("resolv.conf nameservers")
    func resolvConf() {
        let text = """
            # comment
            nameserver 192.0.2.53
            nameserver fe80::1%eth0
            search example.com
            nameserver not-an-ip
            """
        #expect(ResolvConf.nameservers(from: text) == [IPAddress("192.0.2.53")!, IPAddress("fe80::1")!])
    }

    @Test("Upstream specs")
    func upstreamSpecs() {
        #expect(DNSUpstreamSpec("system") == .system)
        #expect(DNSUpstreamSpec("192.0.2.53") == .udp(host: "192.0.2.53", port: 53))
        #expect(DNSUpstreamSpec("192.0.2.53:5353") == .udp(host: "192.0.2.53", port: 5353))
        #expect(DNSUpstreamSpec("[2001:db8::53]:53") == .udp(host: "2001:db8::53", port: 53))
        #expect(DNSUpstreamSpec("2001:db8::53") == .udp(host: "2001:db8::53", port: 53))
        #expect(DNSUpstreamSpec("https://dns.example/dns-query") == .https("https://dns.example/dns-query"))
        #expect(DNSUpstreamSpec("tls://dns.example")?.isSupported == false)
        #expect(DNSUpstreamSpec("dns.example") == nil)
        #expect(DNSUpstreamSpec("192.0.2.53:0") == nil)
    }
}
