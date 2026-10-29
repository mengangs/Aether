import AetherFoundation
import AetherTestSupport
import Foundation
import Testing

@testable import AetherProfile

/// 所有配置与模块 fixtures（含 examples/）。
enum ProfileFixtures {
    static var all: [URL] {
        Fixtures.files(in: "profiles", extensions: ["conf", "amodule", "sgmodule"])
            + Fixtures.files(in: "modules", extensions: ["amodule", "sgmodule"])
            + Fixtures.files(under: Fixtures.examples, extensions: ["conf", "amodule"])
    }
}

struct ProfileDocumentRoundTripTests {
    @Test func fixturesExist() {
        #expect(ProfileFixtures.all.count >= 13)
    }

    @Test(arguments: ProfileFixtures.all)
    func renderIsByteIdentical(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let (document, _) = ProfileDocument.parse(data: data, fileName: url.lastPathComponent)
        let parsed = try #require(document)
        #expect(Data(parsed.render().utf8) == data)
    }
}

struct ProfileDocumentLexerTests {
    private func parse(_ text: String) -> (ProfileDocument, [Diagnostic]) {
        ProfileDocument.parse(text, fileName: "test.conf")
    }

    @Test func classifiesLines() {
        let (document, diagnostics) = parse(
            "#!MANAGED-CONFIG https://example.com/a.conf interval=60\n# c\n\n[General]\nloglevel = info\n[Rule]\nFINAL,DIRECT\n"
        )
        #expect(diagnostics.isEmpty)
        #expect(
            document.lines.map(\.kind) == [
                .directive(name: "MANAGED-CONFIG", value: "https://example.com/a.conf interval=60"),
                .comment,
                .blank,
                .sectionHeader(name: "General"),
                .entry(ProfileEntry(key: "loglevel", value: "info", valueColumn: 12)),
                .sectionHeader(name: "Rule"),
                .entry(ProfileEntry(key: nil, value: "FINAL,DIRECT", valueColumn: 1)),
            ])
        #expect(document.lines.map(\.lineNumber) == Array(1...7))
        #expect(document.metadata.count == 1)
        #expect(document.metadata.first?.name == "MANAGED-CONFIG")
    }

    @Test func sectionNamesAreCaseInsensitiveAndMerged() throws {
        let (document, _) = parse("[ GENERAL ]\nloglevel = info\n[Rule]\nFINAL,DIRECT\n[general]\nipv6 = false\n")
        #expect(document.sectionNames == ["general", "rule"])
        #expect(
            document.entries(in: .general).compactMap { if case .entry(let e) = $0.kind { e.key } else { nil } } == [
                "loglevel", "ipv6",
            ])
    }

    @Test func preservesLineEndingsAndBOM() throws {
        let text = "\u{FEFF}[General]\r\nloglevel = info\nipv6 = false"
        let (document, _) = parse(text)
        #expect(document.hasBOM)
        #expect(document.lineEnding == .crlf)
        #expect(document.lines.map(\.terminator) == ["\r\n", "\n", ""])
        #expect(document.render() == text)
    }

    @Test func reportsSyntaxErrorsButKeepsLines() {
        let (document, diagnostics) = parse(
            "orphan = 1\n[General\n[General]\nno equals\n= v\n[X]\nfree text\n#!LATE x\n")
        #expect(diagnostics.map(\.code) == ["CFG-004", "CFG-004", "CFG-004", "CFG-004", "CFG-003"])
        #expect(diagnostics.map(\.line) == [1, 2, 4, 5, 8])
        #expect(diagnostics.allSatisfy { $0.file == "test.conf" })
        #expect(document.render() == "orphan = 1\n[General\n[General]\nno equals\n= v\n[X]\nfree text\n#!LATE x\n")
        // 未知节的内容保留为条目，由类型化阶段给出 CFG-002。
        #expect(document.lines[6].kind == .entry(ProfileEntry(key: nil, value: "free text", valueColumn: 1)))
    }

    @Test func invalidUTF8IsCFG001() {
        let (document, diagnostics) = ProfileDocument.parse(data: Data([0x5B, 0xFF, 0xFE, 0x5D]), fileName: "bad.conf")
        #expect(document == nil)
        #expect(diagnostics.map(\.code) == ["CFG-001"])
        #expect(diagnostics.first?.severity == .error)
    }

    @Test func valueColumnPointsIntoLine() throws {
        let (document, _) = parse("[Proxy]\n  名字 =   https, a.example.com, 443\n")
        guard case .entry(let entry) = document.lines[1].kind else {
            Issue.record("expected entry")
            return
        }
        #expect(entry.key == "名字")
        #expect(entry.value == "https, a.example.com, 443")
        let scalars = Array(document.lines[1].raw.unicodeScalars)
        #expect(String(String.UnicodeScalarView(scalars[(entry.valueColumn - 1)...])) == "https, a.example.com, 443")
    }

    @Test func diagnosticSeveritiesFollowCatalog() {
        #expect(DiagnosticCatalog.severities.count == 35)
        #expect(Diagnostic(.cfgMissingFinal, file: "f", message: "").severity == .warning)
        #expect(Diagnostic(.cfgIgnoredOnIOS, file: "f", message: "").severity == .info)
        #expect(Diagnostic(.cfgGroupCycle, file: "f", message: "").severity == .error)
        #expect(DiagnosticCatalog.severities.keys.allSatisfy { $0.isWellFormed && $0.namespace == .cfg })
    }
}

struct FieldTokenizerTests {
    private func values(_ text: String) throws -> [String] {
        try FieldTokenizer.split(text).get().map(\.value)
    }

    @Test func splitsSimpleFields() throws {
        #expect(try values(" https , proxy.example.com,443 ") == ["https", "proxy.example.com", "443"])
        #expect(try values("") == [""])
        #expect(try values("a,,b") == ["a", "", "b"])
    }

    @Test func respectsQuotesAndEscapes() throws {
        let fields = try FieldTokenizer.split(#"ws-headers="Host:a.com|User-Agent:x, y", path="a \"b\" \\c""#).get()
        #expect(fields.count == 2)
        #expect(FieldTokenizer.keyValue(fields[0])?.value == "Host:a.com|User-Agent:x, y")
        #expect(FieldTokenizer.keyValue(fields[1])?.value == #"a "b" \c"#)
        #expect(try values(#""a,b", c"#) == ["a,b", "c"])
    }

    @Test func respectsParentheses() throws {
        let fields = try values("AND,((DOMAIN-SUFFIX,example.com),(DEST-PORT,443)),Proxy")
        #expect(fields == ["AND", "((DOMAIN-SUFFIX,example.com),(DEST-PORT,443))", "Proxy"])
        #expect(
            try values(#"(URL-REGEX,"^https://a\.com/(x|y)"),b"#) == [#"(URL-REGEX,"^https://a\.com/(x|y)")"#, "b"])
    }

    @Test func keepsRegexBackslashes() {
        #expect(FieldTokenizer.unquote(#""^https://a\.com/(x|y)""#) == #"^https://a\.com/(x|y)"#)
    }

    @Test func reportsErrors() {
        #expect(FieldTokenizer.split(#"a,"b"#) == .failure(.unterminatedQuote(offset: 2)))
        #expect(FieldTokenizer.split("a,(b") == .failure(.unbalancedParentheses(offset: 4)))
        #expect(FieldTokenizer.split("a),b") == .failure(.unbalancedParentheses(offset: 1)))
    }

    @Test func whitespaceSplitting() throws {
        let fields = try FieldTokenizer.splitWhitespace(
            #"http-response ^https://a\.com/ "\"ads\":true" "\"ads\":false""#
        ).get()
        #expect(fields.map(\.value) == ["http-response", #"^https://a\.com/"#, #""ads":true"#, #""ads":false"#])
        #expect(try FieldTokenizer.splitWhitespace("  a\t b  ").get().map(\.value) == ["a", "b"])
    }

    @Test func keyValueParsing() throws {
        let fields = try FieldTokenizer.split("Password = x=y, udp-relay=true, plain").get()
        #expect(FieldTokenizer.keyValue(fields[0])! == ("password", "x=y"))
        #expect(FieldTokenizer.keyValue(fields[1])! == ("udp-relay", "true"))
        #expect(FieldTokenizer.keyValue(fields[2]) == nil)
    }

    @Test func quoteIfNeeded() {
        #expect(FieldTokenizer.quoteIfNeeded("plain") == "plain")
        #expect(FieldTokenizer.quoteIfNeeded("a,b") == #""a,b""#)
        #expect(FieldTokenizer.quoteIfNeeded(#"say "hi""#) == #""say \"hi\"""#)
    }
}

/// 固定种子的变异模糊测试（docs/04 §15.3）：任意输入不崩溃、不死循环，渲染与输入逐字节一致。
struct ProfileParserFuzzTests {
    static let corpus: [String] = ProfileFixtures.all.compactMap {
        (try? Data(contentsOf: $0)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static let alphabet: [String] = [
        "[", "]", "=", ",", "\"", "\\", "(", ")", "#", "#!", ";", "//", "\n", "\r\n", "\r", " ", "\t", "%APPEND%",
        "{{{", "}}}", "\u{FEFF}", "中", "🇭🇰", "\u{0}", "a", "FINAL", "AND", "\"\"\"",
    ]

    static func mutate(_ input: String, using rng: inout SplitMix64) -> String {
        var scalars = Array(input.unicodeScalars)
        let operations = Int(rng.next() % 8) + 1
        for _ in 0..<operations {
            let position = scalars.isEmpty ? 0 : Int(rng.next() % UInt64(scalars.count + 1))
            switch rng.next() % 4 {
            case 0:
                let token = alphabet[Int(rng.next() % UInt64(alphabet.count))]
                scalars.insert(contentsOf: token.unicodeScalars, at: position)
            case 1 where !scalars.isEmpty:
                let length = min(Int(rng.next() % 16) + 1, scalars.count - min(position, scalars.count - 1))
                let start = min(position, scalars.count - 1)
                scalars.removeSubrange(start..<min(start + length, scalars.count))
            case 2 where !scalars.isEmpty:
                let start = min(position, scalars.count - 1)
                let end = min(start + Int(rng.next() % 64) + 1, scalars.count)
                scalars.insert(contentsOf: scalars[start..<end], at: Int(rng.next() % UInt64(scalars.count + 1)))
            default:
                if let scalar = Unicode.Scalar(UInt32(rng.next() % 0x1_0000)), !(0xD800...0xDFFF).contains(scalar.value)
                {
                    scalars.insert(scalar, at: position)
                }
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    @Test func mutatedInputsRoundTrip() {
        var rng = SplitMix64(seed: 0xAE7E)
        let corpus = Self.corpus.isEmpty ? ["[General]\n"] : Self.corpus
        for iteration in 0..<3000 {
            let seed = corpus[iteration % corpus.count]
            let input = Self.mutate(seed, using: &rng)
            let (document, _) = ProfileDocument.parse(input, fileName: "fuzz.conf")
            if document.render() != input {
                Issue.record("round trip failed at iteration \(iteration)")
                return
            }
        }
    }

    @Test func randomFieldsNeverCrashTokenizer() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<3000 {
            let length = Int(rng.next() % 40)
            let text = (0..<length).map { _ in Self.alphabet[Int(rng.next() % UInt64(Self.alphabet.count))] }.joined()
            _ = FieldTokenizer.split(text)
            _ = FieldTokenizer.splitWhitespace(text)
        }
    }
}
