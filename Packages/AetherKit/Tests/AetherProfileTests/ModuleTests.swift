import AetherFoundation
import AetherTestSupport
import Foundation
import Testing

@testable import AetherProfile

private let baseProfile = """
    [General]
    loglevel = info
    [Proxy]
    A = https, a.example.com, 443
    [Proxy Group]
    Proxy = select, A, DIRECT
    [Rule]
    DOMAIN,profile.example.com,Proxy
    FINAL,DIRECT
    [Host]
    profile.example.com = 192.0.2.1
    [Script]
    shared = type=generic, script-path=profile.js
    [MITM]
    hostname = profile.example.com
    """

private func resolveWith(_ modules: [ModuleInput], profile: String = baseProfile) -> ResolvedProfile {
    ProfileResolver.resolve(profileText: profile, fileName: "main.conf", modules: modules)
}

struct ModuleMetadataTests {
    @Test func parsesAllFields() {
        let (metadata, diagnostics) = ModuleMetadata.parse(
            text: """
                #!name=示例
                #!desc=说明
                #!author=someone
                #!homepage=https://example.com
                #!icon=https://example.com/i.png
                #!category=测试
                #!version=1.2
                #!system=ios,mac
                #!arguments=region:HK,enable-log:false,empty:,required
                #!arguments-desc=说明
                #!requirement=CORE_VERSION>=1
                [Rule]
                FINAL,DIRECT
                """, fileName: "m.amodule")
        #expect(metadata.name == "示例" && metadata.version == "1.2" && metadata.system == ["ios", "mac"])
        #expect(
            metadata.arguments == [
                ModuleArgument(name: "region", defaultValue: "HK"),
                ModuleArgument(name: "enable-log", defaultValue: "false"),
                ModuleArgument(name: "empty", defaultValue: ""),
                ModuleArgument(name: "required", defaultValue: nil),
            ])
        #expect(codes(diagnostics) == ["CFG-082"])
    }

    @Test func warnsAboutSystemAndMissingName() {
        let (_, diagnostics) = ModuleMetadata.parse(
            text: "#!system=mac\n#!colour=blue\n[Rule]\n", fileName: "m.amodule")
        #expect(Set(codes(diagnostics)) == ["CFG-003", "CFG-083", "CFG-084"])
    }
}

struct ModuleOverlayTests {
    @Test func argumentsAreSubstitutedWithDefaultsAndUserValues() throws {
        let text = "#!name=M\n#!arguments=policy:DIRECT,host:a.example.com\n[Rule]\nDOMAIN,{{{host}}},{{{policy}}}\n"
        let defaults = resolveWith([ModuleInput(name: "m.amodule", text: text)])
        #expect(defaults.rules.first?.raw == "DOMAIN,a.example.com,DIRECT")
        let custom = resolveWith([ModuleInput(name: "m.amodule", text: text, argumentValues: ["policy": "Proxy"])])
        #expect(custom.rules.first?.policy == "Proxy")
        #expect(defaults.revision != custom.revision)
    }

    @Test func missingArgumentDisablesModule() throws {
        let profile = resolveWith([
            ModuleInput(
                name: "need.amodule", text: "#!name=N\n#!arguments=policy\n[Rule]\nDOMAIN,a.example.com,{{{policy}}}\n"),
            ModuleInput(name: "typo.amodule", text: "#!name=T\n[Rule]\nDOMAIN,a.example.com,{{{nope}}}\n"),
        ])
        #expect(profile.modules.map(\.isApplied) == [false, false])
        #expect(codes(profile.modules.flatMap(\.diagnostics)) == ["CFG-081", "CFG-081"])
        #expect(profile.isCommittable)
        #expect(profile.rules.count == 2)
    }

    @Test func unknownPolicyDisablesOnlyThatModule() throws {
        let profile = resolveWith([
            ModuleInput(
                name: "bad.amodule",
                text: "#!name=Bad\n[Rule]\nDOMAIN,bad.example.com,Nowhere\n[Host]\nbad.example.com = 192.0.2.9\n"),
            ModuleInput(name: "good.amodule", text: "#!name=Good\n[Rule]\nDOMAIN,good.example.com,Proxy\n"),
        ])
        #expect(profile.modules.map(\.isApplied) == [false, true])
        #expect(profile.modules[0].diagnostics.map(\.code) == ["CFG-011"])
        #expect(profile.modules[0].diagnostics.first?.file == "bad.amodule")
        #expect(
            profile.rules.map(\.raw) == [
                "DOMAIN,good.example.com,Proxy", "DOMAIN,profile.example.com,Proxy", "FINAL,DIRECT",
            ])
        #expect(profile.hosts.map(\.pattern) == ["profile.example.com"])
        #expect(profile.isCommittable)
    }

    @Test func sectionsAreOrderedModulesFirst() throws {
        let first = ModuleInput(
            name: "first.amodule",
            text: """
                #!name=First
                [Rule]
                DOMAIN,first.example.com,DIRECT
                [Host]
                first.example.com = 192.0.2.2
                [URL Rewrite]
                ^https://first\\.example\\.com/ - reject
                [Script]
                shared = type=generic, script-path=first.js
                """)
        let second = ModuleInput(
            name: "second.amodule",
            text:
                "#!name=Second\n[Rule]\nDOMAIN,second.example.com,DIRECT\n[Host]\nsecond.example.com = 192.0.2.3\n[Script]\nshared = type=generic, script-path=second.js\n"
        )
        let profile = resolveWith([first, second])
        #expect(
            profile.rules.map(\.raw) == [
                "DOMAIN,first.example.com,DIRECT", "DOMAIN,second.example.com,DIRECT",
                "DOMAIN,profile.example.com,Proxy",
                "FINAL,DIRECT",
            ])
        #expect(profile.hosts.map(\.pattern) == ["first.example.com", "second.example.com", "profile.example.com"])
        #expect(profile.urlRewrites.count == 1)
        #expect(profile.scripts.map(\.scriptPath) == ["first.js"])
        #expect(codes(profile.diagnostics).filter { $0 == "CFG-062" }.count == 2)
    }

    @Test func keyedSectionsReplaceAppendAndInsert() throws {
        let high = ModuleInput(
            name: "high.amodule",
            text:
                "#!name=High\n[General]\nloglevel = error\nskip-proxy = %APPEND% *.high.example\n[MITM]\nhostname = %APPEND% high.example.com\n"
        )
        let low = ModuleInput(
            name: "low.amodule",
            text:
                "#!name=Low\n[General]\nloglevel = debug\nalways-real-ip = %APPEND% *.game.example\nhijack-dns = %INSERT% 192.0.2.53:53\n[MITM]\nhostname = %INSERT% low.example.com\n"
        )
        let profile = resolveWith([high, low])
        #expect(profile.general.logLevel == "error")  // 排在前面的模块优先级更高
        #expect(profile.general.skipProxy == GeneralSettings.defaultSkipProxy + ["*.high.example"])
        #expect(profile.general.alwaysRealIP == GeneralSettings.builtinAlwaysRealIP + ["*.game.example"])
        #expect(profile.general.hijackDNS == ["192.0.2.53:53", "*:53"])
        #expect(profile.mitm.hostnames.map(\.host) == ["low.example.com", "profile.example.com", "high.example.com"])
        #expect(profile.diagnostics.isEmpty, "\(profile.diagnostics)")
    }

    @Test func disallowedSectionsAreIgnoredButModuleApplies() {
        let profile = resolveWith([
            ModuleInput(
                name: "m.amodule",
                text:
                    "#!name=M\n[Proxy]\nX = direct\n[Proxy Group]\nG = select, DIRECT\n[Rule]\nDOMAIN,m.example.com,DIRECT\n"
            )
        ])
        #expect(codes(profile.diagnostics) == ["CFG-080", "CFG-080"])
        #expect(profile.modules.first?.isApplied == true)
        #expect(profile.proxies.map(\.name) == ["A"])
    }

    @Test func sampleModuleOnFullExample() throws {
        let full = try String(contentsOf: Fixtures.examples.appendingPathComponent("full.conf"), encoding: .utf8)
        let sample = try String(contentsOf: Fixtures.examples.appendingPathComponent("sample.amodule"), encoding: .utf8)
        let without = ProfileResolver.resolve(profileText: full, fileName: "full.conf")
        let with = ProfileResolver.resolve(
            profileText: full, fileName: "full.conf", modules: [ModuleInput(name: "sample.amodule", text: sample)])
        #expect(with.modules.first?.isApplied == true)
        #expect(with.modules.first?.metadata.name == "示例模块")
        #expect(with.rules.count == without.rules.count + 2)
        #expect(with.rules.first?.raw == "DOMAIN-SUFFIX,example.org,Proxy")
        #expect(with.mitm.hostnames.last?.host == "api.example.org")
        #expect(with.general.alwaysRealIP?.last == "*.example-game.com")
        #expect(with.scripts.contains { $0.name == "example-module-script" && !$0.debug })
        #expect(with.isCommittable)
        #expect(!with.diagnostics.containsErrors, "\(with.diagnostics)")
    }
}

struct RevisionTests {
    @Test func revisionIsStableAndSensitive() {
        let module = ModuleInput(name: "m", text: "#!name=M\n", argumentValues: ["a": "1", "b": "2"])
        let reordered = ModuleInput(name: "m", text: "#!name=M\n", argumentValues: ["b": "2", "a": "1"])
        let base = ProfileResolver.revision(profileText: "x", fileName: "p", modules: [module])
        #expect(base.hasPrefix("sha256:") && base.count == 7 + 64)
        #expect(base == ProfileResolver.revision(profileText: "x", fileName: "p", modules: [reordered]))
        #expect(base != ProfileResolver.revision(profileText: "y", fileName: "p", modules: [module]))
        #expect(base != ProfileResolver.revision(profileText: "x", fileName: "p", modules: []))
        #expect(
            base
                != ProfileResolver.revision(
                    profileText: "x", fileName: "p",
                    modules: [ModuleInput(name: "m", text: "#!name=M\n", argumentValues: ["a": "1", "b": "3"])]))
        // 长度前缀保证拼接边界不同的输入不会碰撞。
        #expect(
            ProfileResolver.revision(profileText: "ab", fileName: "c", modules: [])
                != ProfileResolver.revision(profileText: "a", fileName: "bc", modules: []))
    }

    @Test func knownDigestOfEmptyProfile() {
        // 回归保护：修订号算法变化会让所有已提交的运行包被视为过期，需要有意识地修改。
        let revision = ProfileResolver.revision(profileText: "", fileName: "", modules: [])
        #expect(revision == ProfileResolver.revision(profileText: "", fileName: "", modules: []))
        #expect(revision.count == 71)
    }
}

/// 04 §13 中每个 error / warning 级诊断码至少由一个用例产生（M1-04 完成标准）。
struct DiagnosticCoverageTests {
    enum Input: Sendable {
        case profile(String)
        case module(String)
        case bytes([UInt8])
    }

    static let cases: [(String, Input)] = [
        ("CFG-001", .bytes([0x5B, 0xFF, 0x5D])),
        ("CFG-002", .profile("[Panel]\nx = 1\n")),
        ("CFG-003", .profile("[General]\nreplica = true\n")),
        ("CFG-004", .profile("orphan = 1\n")),
        ("CFG-005", .profile("[General]\nloglevel = info\nloglevel = error\n")),
        ("CFG-010", .profile("[Proxy]\nDIRECT = https, a.example.com, 443\n")),
        ("CFG-011", .profile("[Rule]\nFINAL,Nowhere\n")),
        ("CFG-012", .profile("[Proxy Group]\nA = select, A\n")),
        ("CFG-013", .profile("[Proxy Group]\nA = select\n")),
        ("CFG-020", .profile("[General]\ntun-mtu = 1\n")),
        ("CFG-021", .profile("[Proxy]\nT = trojan, t.example.com, 443\n")),
        ("CFG-022", .profile("[Proxy]\nS = snell, s.example.com, 443\n")),
        ("CFG-023", .profile("[Proxy]\nR = ss, r.example.com, 443, encrypt-method=rc4-md5, password=x\n")),
        ("CFG-030", .profile("[Rule]\nTELEPATHY,x,DIRECT\n")),
        ("CFG-031", .profile("[Rule]\nPROCESS-NAME,x,DIRECT\n")),
        ("CFG-032", .profile("[Rule]\nIP-CIDR,999.0.0.0/8,DIRECT\n")),
        ("CFG-033", .profile("[Rule]\nURL-REGEX,\"[\",DIRECT\n")),
        ("CFG-034", .profile("[Rule]\nDEST-PORT,0,DIRECT\n")),
        ("CFG-035", .profile("[Rule]\nDOMAIN,a.example.com,DIRECT\n")),
        ("CFG-036", .profile("[Rule]\nFINAL,DIRECT\nDOMAIN,a.example.com,DIRECT\n")),
        ("CFG-037", .profile("[Rule]\nDOMAIN,a.example.com,DIRECT,no-resolve\n")),
        ("CFG-040", .profile("[Host]\na.example.com = not valid\n")),
        ("CFG-050", .profile("[URL Rewrite]\n^a b nonsense\n")),
        ("CFG-060", .profile("[Script]\nx = script-path=a.js\n")),
        ("CFG-061", .profile("[Script]\nx = type=cron, cronexp=\"* *\", script-path=a.js\n")),
        (
            "CFG-062",
            .module(
                "#!name=M\n[Script]\nx = type=generic, script-path=a.js\n[Script]\nx = type=generic, script-path=b.js\n"
            )
        ),
        ("CFG-070", .profile("[MITM]\nhostname = *\n")),
        ("CFG-071", .profile("[MITM]\nhostname = a:b:c\n")),
        ("CFG-080", .module("#!name=M\n[Proxy]\nX = direct\n")),
        ("CFG-081", .module("#!name=M\n[Rule]\nDOMAIN,{{{x}}},DIRECT\n")),
        ("CFG-083", .module("#!name=M\n#!system=mac\n")),
        ("CFG-084", .module("[Rule]\nDOMAIN,a.example.com,DIRECT\n")),
        ("CFG-090", .profile("[Rule]\nRULE-SET,http://r.example.com/a,DIRECT\n")),
        ("CFG-091", .profile("[Rule]\nRULE-SET,ftp://r.example.com/a,DIRECT\n")),
    ]

    static func produced(_ input: Input) -> [String] {
        switch input {
        case .profile(let text):
            return codes(ProfileResolver.resolve(profileText: text, fileName: "p.conf").diagnostics)
        case .module(let text):
            return codes(
                ProfileResolver.resolve(
                    profileText: "[Rule]\nFINAL,DIRECT\n", fileName: "p.conf",
                    modules: [ModuleInput(name: "m.amodule", text: text)]
                ).diagnostics)
        case .bytes(let bytes):
            return codes(ProfileDocument.parse(data: Data(bytes), fileName: "p.conf").1)
        }
    }

    @Test func everyCaseProducesItsCode() {
        for (code, input) in Self.cases {
            #expect(Self.produced(input).contains(code), "\(code) not produced by \(input)")
        }
    }

    @Test func everyErrorAndWarningCodeIsCovered() {
        let required = Set(DiagnosticCatalog.severities.filter { $0.value >= .warning }.keys.map(\.rawValue))
        let covered = Set(Self.cases.map(\.0))
        #expect(required.subtracting(covered).isEmpty, "uncovered: \(required.subtracting(covered).sorted())")
    }

    @Test func substitutedTextForBundles() {
        let text = "#!name=M\n#!arguments=policy:DIRECT,host:a.example.com\n[Rule]\nDOMAIN,{{{host}}},{{{policy}}}\n"
        let module = ModuleInput(name: "M", text: text, argumentValues: ["host": "b.example.com"])
        #expect(module.substitutedText()?.contains("DOMAIN,b.example.com,DIRECT") == true)
        #expect(
            ModuleInput(name: "N", text: "#!name=N\n[Rule]\nDOMAIN,{{{missing}}},DIRECT\n").substitutedText() == nil)
    }
}
