import AetherTestSupport
import Foundation
import Testing

@testable import AetherProfile

struct EditingTests {
    static let text =
        "# head\r\n[General]\r\n  loglevel   =   info\r\n\r\n[Rule]\r\nDOMAIN,a.example.com,DIRECT\r\nFINAL,DIRECT"

    private func document() -> ProfileDocument {
        ProfileDocument.parse(Self.text, fileName: "e.conf").0
    }

    private func entryID(_ document: ProfileDocument, containing text: String) throws -> LineID {
        try #require(document.lines.first { $0.raw.contains(text) }).id
    }

    /// 只有 `changed` 中的行与原文不同。
    private func changedLines(_ before: String, _ after: String) -> [String] {
        let a = before.components(separatedBy: "\r\n")
        let b = after.components(separatedBy: "\r\n")
        return b.filter { !a.contains($0) }
    }

    @Test func updateKeepsKeyFormattingAndOtherLines() throws {
        var doc = document()
        let id = try entryID(doc, containing: "loglevel")
        try doc.updateEntry(id: id, newValue: "debug")
        #expect(doc.render() == Self.text.replacingOccurrences(of: "=   info", with: "=   debug"))
        #expect(doc.line(id)?.kind == .entry(ProfileEntry(key: "loglevel", value: "debug", valueColumn: 18)))
    }

    @Test func insertUsesDocumentLineEndingAndKeepsMissingFinalNewline() throws {
        var doc = document()
        let rule = try entryID(doc, containing: "DOMAIN,a")
        let inserted = try doc.insertEntry(in: .rule, after: rule, raw: "DOMAIN,b.example.com,REJECT")
        #expect(
            doc.render()
                == Self.text.replacingOccurrences(
                    of: "DOMAIN,a.example.com,DIRECT\r\n",
                    with: "DOMAIN,a.example.com,DIRECT\r\nDOMAIN,b.example.com,REJECT\r\n"))
        #expect(doc.line(inserted)?.lineNumber == 7)
        try doc.insertEntry(in: .rule, raw: "DOMAIN,c.example.com,DIRECT")
        #expect(doc.render().hasSuffix("FINAL,DIRECT\r\nDOMAIN,c.example.com,DIRECT"))
        #expect(doc.lines.map(\.lineNumber) == Array(1...doc.lines.count))
    }

    @Test func insertCreatesMissingSection() throws {
        var doc = ProfileDocument.parse("[General]\nloglevel = info\n", fileName: "e.conf").0
        try doc.insertEntry(in: .proxyGroup, raw: "Proxy = select, DIRECT")
        #expect(doc.render() == "[General]\nloglevel = info\n\n[Proxy Group]\nProxy = select, DIRECT\n")
        let reparsed = ProfileDocument.parse(doc.render(), fileName: "e.conf").0
        #expect(reparsed.entries(in: .proxyGroup).count == 1)
    }

    @Test func removeAndMove() throws {
        var doc = document()
        let final = try entryID(doc, containing: "FINAL")
        let domain = try entryID(doc, containing: "DOMAIN,a")
        try doc.moveEntry(id: final, after: nil)
        #expect(doc.render().hasSuffix("[Rule]\r\nFINAL,DIRECT\r\nDOMAIN,a.example.com,DIRECT"))
        try doc.moveEntry(id: final, after: domain)
        #expect(doc.render() == Self.text)
        try doc.removeEntry(id: final)
        #expect(
            doc.render() == "# head\r\n[General]\r\n  loglevel   =   info\r\n\r\n[Rule]\r\nDOMAIN,a.example.com,DIRECT")
    }

    @Test func rejectsInvalidEdits() throws {
        var doc = document()
        let header = try #require(doc.lines.first { $0.raw == "[Rule]" }).id
        let level = try entryID(doc, containing: "loglevel")
        #expect(throws: ProfileDocument.EditError.notAnEntry(header)) { try doc.updateEntry(id: header, newValue: "x") }
        #expect(throws: ProfileDocument.EditError.invalidRaw("a\nb")) { try doc.insertEntry(in: .rule, raw: "a\nb") }
        #expect(throws: ProfileDocument.EditError.invalidRaw("no equals")) {
            try doc.replaceEntry(id: level, raw: "no equals")
        }
        #expect(throws: ProfileDocument.EditError.differentSection) {
            try doc.insertEntry(in: .rule, after: level, raw: "FINAL,DIRECT")
        }
        #expect(throws: ProfileDocument.EditError.lineNotFound(LineID(999))) { try doc.removeEntry(id: LineID(999)) }
        #expect(doc.render() == Self.text)
    }

    @Test func randomEditSequencesStayConsistent() throws {
        var rng = SplitMix64(seed: 99)
        var doc = document()
        for step in 0..<300 {
            let entries = doc.lines.filter {
                if case .entry = $0.kind { return $0.section == .rule } else { return false }
            }
            switch rng.next() % 4 {
            case 0: try doc.insertEntry(in: .rule, raw: "DOMAIN,s\(step).example.com,DIRECT")
            case 1 where !entries.isEmpty: try doc.removeEntry(id: entries[Int(rng.next() % UInt64(entries.count))].id)
            case 2 where entries.count > 1:
                let a = entries[Int(rng.next() % UInt64(entries.count))].id
                let b = entries[Int(rng.next() % UInt64(entries.count))].id
                if a != b { try doc.moveEntry(id: a, after: b) }
            case 3 where !entries.isEmpty:
                try doc.updateEntry(
                    id: entries[Int(rng.next() % UInt64(entries.count))].id,
                    newValue: "DOMAIN,u\(step).example.com,REJECT")
            default: break
            }
            // 不变量：渲染后重新解析得到相同的行原文与分类；行号连续；ID 唯一。
            let reparsed = ProfileDocument.parse(doc.render(), fileName: "e.conf").0
            #expect(reparsed.lines.map(\.raw) == doc.lines.map(\.raw))
            #expect(reparsed.lines.map(\.kind) == doc.lines.map(\.kind))
            #expect(doc.lines.map(\.lineNumber) == Array(1...doc.lines.count))
            #expect(Set(doc.lines.map(\.id)).count == doc.lines.count)
        }
        #expect(!doc.render().hasSuffix("\n"))
    }
}

struct RedactionTests {
    static func entryKeys(_ document: ProfileDocument) -> [String?] {
        document.lines.map { line -> String? in
            guard case .entry(let entry) = line.kind else { return nil }
            return entry.key
        }
    }

    private func redacted(_ text: String) -> String {
        ProfileDocument.parse(text, fileName: "r.conf").0.render(redactingSecrets: true)
    }

    @Test(arguments: [
        (
            "[Proxy]\nA = https, a.example.com, 443, alice, s3cret, sni=a.example.com\n",
            "[Proxy]\nA = https, a.example.com, 443, alice, ******, sni=a.example.com\n"
        ),
        (
            "[Proxy]\nB = socks5, 192.0.2.1, 1080, username=bob, password=pw\n",
            "[Proxy]\nB = socks5, 192.0.2.1, 1080, username=bob, password=******\n"
        ),
        (
            "[Proxy]\nC = ss, c.example.com, 8388, encrypt-method=aes-128-gcm, Password = \"p,w\"\n",
            "[Proxy]\nC = ss, c.example.com, 8388, encrypt-method=aes-128-gcm, Password =******\n"
        ),
        (
            "[Proxy]\nD = vmess, d.example.com, 443, username=b831381d-6324-4d53-ad4f-8cda48b30811, tls=true\n",
            "[Proxy]\nD = vmess, d.example.com, 443, username=******, tls=true\n"
        ),
        (
            "[Proxy]\nE = tuic, e.example.com, 443, uuid=x, password=y, token=z\n",
            "[Proxy]\nE = tuic, e.example.com, 443, uuid=******, password=******, token=******\n"
        ),
        (
            "[Proxy Group]\nS = select, policy-path=https://sub.example.com/list?token=abc#frag, hidden=true\n",
            "[Proxy Group]\nS = select, policy-path=https://sub.example.com/list?******#frag, hidden=true\n"
        ),
        ("[General]\nhttp-api = mykey@127.0.0.1:6170\n", "[General]\nhttp-api = ******@127.0.0.1:6170\n"),
        (
            "[MITM]\nca-p12 = MIIKAAA\nca-passphrase   =  hunter2  \n",
            "[MITM]\nca-p12 = ******\nca-passphrase   =  ******  \n"
        ),
        (
            "#!MANAGED-CONFIG https://config.example.com/a.conf?key=secret interval=60\n[General]\n",
            "#!MANAGED-CONFIG https://config.example.com/a.conf?****** interval=60\n[General]\n"
        ),
        ("[Proxy]\nF = https, f.example.com, 443, \"unterminated\n", "[Proxy]\nF = ******\n"),
    ])
    func redactsSensitiveValues(_ input: String, _ expected: String) {
        #expect(redacted(input) == expected)
    }

    @Test func leavesEverythingElseUntouched() throws {
        let text =
            "[Proxy]\nP = http, p.example.com, 8080\n[Rule]\nDOMAIN,password.example.com,DIRECT\n# password=visible-in-comment\n"
        #expect(redacted(text) == text)
    }

    @Test func fullExampleLeaksNoSecrets() throws {
        let text = try String(contentsOf: Fixtures.examples.appendingPathComponent("full.conf"), encoding: .utf8)
        let output = redacted(text)
        #expect(!output.contains("password=example-password"))
        #expect(!output.contains(", example-password"))
        #expect(!output.contains("b831381d-6324-4d53-ad4f-8cda48b30811"))
        #expect(!output.contains("token=REDACTED"))
        #expect(!output.contains("AAAAAAAAAAAAAAAAAAAAAA=="))
        #expect(output.components(separatedBy: "\n").count == text.components(separatedBy: "\n").count)
        // 脱敏只改值：每一行的分类（节、键、条目）保持不变。UUID 类节点在脱敏后不再是合法配置，这是预期的。
        let original = ProfileDocument.parse(text, fileName: "full.conf").0
        let masked = ProfileDocument.parse(output, fileName: "full.conf").0
        #expect(masked.lines.map(\.sectionName) == original.lines.map(\.sectionName))
        #expect(Self.entryKeys(masked) == Self.entryKeys(original))
    }
}
