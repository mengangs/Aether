import AetherFoundation
import AetherTestSupport
import Testing

@testable import AetherProfile

func resolve(_ text: String) -> ResolvedProfile {
    ProfileResolver.resolve(profileText: text, fileName: "test.conf")
}

struct ValidationTests {
    @Test func validProfileHasNoDiagnostics() {
        let profile = resolve(
            """
            [Proxy]
            A = https, a.example.com, 443
            B = socks5, 192.0.2.1, 1080, underlying-proxy=A
            [Proxy Group]
            Proxy = select, Auto, A, direct
            Auto = url-test, A, B
            [Rule]
            DOMAIN-SUFFIX,example.com,Proxy
            FINAL,Auto
            """)
        #expect(codes(profile.diagnostics) == ["CFG-099"])  // underlying-proxy 是 M7 能力
        #expect(profile.isCommittable)
        #expect(profile.rules.count == 2)
    }

    @Test func duplicateAndBuiltinNamesAreCFG010() {
        let profile = resolve(
            """
            [Proxy]
            A = https, a.example.com, 443
            A = https, b.example.com, 443
            Direct = https, c.example.com, 443
            [Proxy Group]
            A = select, DIRECT
            REJECT = select, DIRECT
            [Rule]
            FINAL,DIRECT
            """)
        #expect(codes(profile.diagnostics) == ["CFG-010", "CFG-010", "CFG-010", "CFG-010"])
        #expect(profile.diagnostics.map(\.line) == [3, 4, 6, 7])
        #expect(!profile.isCommittable)
    }

    @Test func unknownReferencesAreCFG011() {
        let profile = resolve(
            """
            [General]
            resource-fetch-policy = Nowhere
            [Proxy]
            A = https, a.example.com, 443, underlying-proxy=Ghost
            [Proxy Group]
            G = select, A, Missing, include-other-group="Phantom"
            [Rule]
            DOMAIN,example.com,Unknown
            AND,((DOMAIN,a.example.com),(DEST-PORT,443)),Also-Unknown
            FINAL,G
            """)
        let unknown = profile.diagnostics.filter { $0.code == .cfgUnknownPolicy }
        #expect(unknown.map(\.arguments.last) == ["Missing", "Phantom", "Unknown", "Also-Unknown", "Nowhere", "Ghost"])
    }

    @Test func builtinReferencesAreCaseInsensitive() {
        let profile = resolve("[Proxy Group]\nG = select, direct, Reject-Tinygif\n[Rule]\nFINAL,reject\n")
        #expect(profile.diagnostics.isEmpty)
    }

    @Test func groupCyclesAreCFG012() {
        let profile = resolve(
            """
            [Proxy Group]
            A = select, B
            B = select, C, DIRECT
            C = select, A
            Self = select, Self
            Inc = select, DIRECT, include-other-group="Inc2"
            Inc2 = select, Inc
            [Rule]
            FINAL,DIRECT
            """)
        let cycles = profile.diagnostics.filter { $0.code == .cfgGroupCycle }
        #expect(cycles.count == 3)
        #expect(cycles.first?.arguments == ["A → B → C → A"])
        #expect(!profile.isCommittable)
    }

    @Test func groupWithoutMembersIsCFG013() {
        let profile = resolve(
            "[Proxy Group]\nEmpty = select, hidden=true\nSub = select, policy-path=https://sub.example.com/a\n[Rule]\nFINAL,DIRECT\n"
        )
        #expect(codes(profile.diagnostics) == ["CFG-013"])
    }

    @Test func missingFinalIsAppended() throws {
        let profile = resolve("[Rule]\nDOMAIN,example.com,DIRECT\n")
        #expect(codes(profile.diagnostics) == ["CFG-035"])
        let last = try #require(profile.rules.last)
        #expect(last.condition == .final && last.policy == "DIRECT")
        #expect(profile.isCommittable)
    }

    @Test func rulesAfterFinalAreDropped() {
        let profile = resolve("[Rule]\nFINAL,DIRECT\nDOMAIN,example.com,REJECT\nDOMAIN,example.net,REJECT\n")
        #expect(codes(profile.diagnostics) == ["CFG-036", "CFG-036"])
        #expect(profile.rules.count == 1)
    }

    @Test func resourcesAreDeduplicated() {
        let profile = resolve(
            """
            [Rule]
            RULE-SET,https://r.example.com/a.list,DIRECT
            RULE-SET,https://r.example.com/a.list,REJECT
            DOMAIN-SET,https://r.example.com/a.list,DIRECT
            FINAL,DIRECT
            """)
        #expect(profile.externalResources.map(\.kind) == [.ruleSet, .domainSet])
    }

    @Test func fullExampleResolvesCleanly() throws {
        let text = try String(contentsOf: Fixtures.examples.appendingPathComponent("full.conf"), encoding: .utf8)
        let profile = ProfileResolver.resolve(profileText: text, fileName: "full.conf")
        #expect(!profile.diagnostics.containsErrors, "\(profile.diagnostics)")
        #expect(profile.isCommittable)
        #expect(
            Set(profile.externalResources.map(\.kind)) == [.geoIPDatabase, .ruleSet, .domainSet, .policyPath, .script])
    }
}
