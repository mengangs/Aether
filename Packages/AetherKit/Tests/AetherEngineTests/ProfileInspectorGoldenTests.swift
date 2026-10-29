import AetherFoundation
import AetherRules
import AetherTestSupport
import Foundation
import Testing

@testable import AetherEngine

/// aether-cli 输出的黄金文件测试（docs/13 §2）。设置环境变量 `AETHER_UPDATE_GOLDEN=1` 运行时重写期望文件；
/// 更新黄金文件需要在提交说明中写明原因。
enum Golden {
    static func check(_ output: String, _ name: String) {
        let url = Fixtures.url("cli/\(name).expected")
        if ProcessInfo.processInfo.environment["AETHER_UPDATE_GOLDEN"] == "1" {
            try? Data(output.utf8).write(to: url)
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("missing golden file \(name).expected")
            return
        }
        #expect(output == expected, "golden \(name) differs")
    }

    static func source(_ path: String) throws -> ProfileInspector.Source {
        ProfileInspector.Source(name: URL(fileURLWithPath: path).lastPathComponent, text: try Fixtures.string(path))
    }
}

struct ProfileInspectorGoldenTests {
    static var resources: [String: String] {
        [
            "https://rules.example.com/ads.list": (try? Fixtures.string("rulesets/ads.list")) ?? "",
            "https://rules.example.com/streaming.txt": (try? Fixtures.string("rulesets/streaming.txt")) ?? "",
        ]
    }

    @Test func checkFullExample() throws {
        let result = ProfileInspector.check(try Golden.source("cli/full.conf"))
        #expect(result.exitCode == 0)
        Golden.check(result.output, "check-full")
    }

    @Test func checkWithModule() throws {
        let module = ProfileInspector.Source(
            name: "sample.amodule",
            text: try String(contentsOf: Fixtures.examples.appendingPathComponent("sample.amodule"), encoding: .utf8))
        let result = ProfileInspector.check(try Golden.source("cli/full.conf"), modules: [module])
        #expect(result.exitCode == 0)
        Golden.check(result.output, "check-full-module")
    }

    @Test func checkBrokenProfile() throws {
        let result = ProfileInspector.check(try Golden.source("cli/broken.conf"))
        #expect(result.exitCode == 1)
        Golden.check(result.output, "check-broken")
    }

    @Test func renderRedacted() throws {
        Golden.check(ProfileInspector.render(try Golden.source("cli/full.conf"), redact: true), "render-full-redacted")
        let plain = try Golden.source("cli/full.conf")
        #expect(ProfileInspector.render(plain, redact: false) == plain.text)
    }

    @Test(arguments: [
        ("match-url", "https://api.example.com/v2/config", ["api.example.com": "198.51.100.50"]),
        ("match-ads", "https://x.ads.example.com/banner", [:]),
        ("match-ads-by-ip", "https://img.example.com/a.png", ["img.example.com": "203.0.113.7"]),
        ("match-streaming", "video.example.net", ["video.example.net": "198.51.100.51"]),
        ("match-lan-ip", "192.168.1.20", [:]),
        ("match-geoip-resolve", "www.example.edu", ["www.example.edu": "198.51.100.30"]),
        ("match-dns-failed", "unresolvable.example.edu", [:]),
        ("match-quic", "quic.example.edu", ["quic.example.edu": "198.51.100.52"]),
    ])
    func match(_ name: String, _ target: String, _ resolutions: [String: String]) throws {
        var query = ProfileInspector.MatchQuery(target: target)
        if name == "match-quic" {
            query.transport = .udp
            query.appProtocol = .quic
        }
        for (host, address) in resolutions {
            query.resolutions[host] = [try #require(IPAddress(address))]
        }
        query.selections = ["Proxy": "HK-01"]
        let output = ProfileInspector.match(try Golden.source("cli/full.conf"), query: query, resources: Self.resources)
        Golden.check(output, name)
    }
}
