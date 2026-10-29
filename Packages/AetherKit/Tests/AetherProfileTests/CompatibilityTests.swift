import AetherFoundation
import AetherTestSupport
import Foundation
import Testing

@testable import AetherProfile

/// 兼容 fixtures（docs/04 §14）：风格各异的配置及期望的解析摘要与诊断，作为回归测试。
/// 设置 `AETHER_UPDATE_GOLDEN=1` 重写 `.expected`，重写后须逐个人工检查。
struct CompatibilityTests {
    static var files: [URL] { Fixtures.files(in: "profiles/compat", extensions: ["conf"]) }

    @Test func atLeastTenFixtures() {
        #expect(Self.files.count >= 10)
    }

    @Test(arguments: files)
    func matchesExpectedSummary(_ url: URL) throws {
        let data = try Data(contentsOf: url)
        let (document, _) = ProfileDocument.parse(data: data, fileName: url.lastPathComponent)
        let text = try #require(document).render()
        let resolved = ProfileResolver.resolve(profileText: text, fileName: url.lastPathComponent)
        let summary = Self.summary(resolved)
        let expectedURL = url.deletingPathExtension().appendingPathExtension("expected")
        if ProcessInfo.processInfo.environment["AETHER_UPDATE_GOLDEN"] == "1" {
            try Data(summary.utf8).write(to: expectedURL)
            return
        }
        let expected = try String(contentsOf: expectedURL, encoding: .utf8)
        #expect(summary == expected, "\(url.lastPathComponent) differs from its .expected")
    }

    static func summary(_ profile: ResolvedProfile) -> String {
        var lines: [String] = ["profile: \(profile.profileFileName)"]
        let g = profile.general
        lines.append(
            "general: loglevel=\(g.logLevel) dns-mode=\(g.dnsMode.rawValue) dns-server=\(g.dnsServers) encrypted=\(g.encryptedDNSServers) "
                + "ipv6=\(g.ipv6) system-proxy=\(g.systemProxy) mtu=\(g.tunMTU) block-quic=\(g.blockQUIC.rawValue) "
                + "fake-ip=\(g.fakeIPRange) skip-proxy=\(g.skipProxy.count) hijack=\(g.hijackDNS)")
        lines.append("proxies (\(profile.proxies.count)):")
        for proxy in profile.proxies {
            var flags: [String] = [proxy.isUsable ? "usable" : "unavailable"]
            if proxy.tls != nil { flags.append("tls") }
            if proxy.webSocket != nil { flags.append("ws") }
            if proxy.udpRelay { flags.append("udp") }
            let endpoint = proxy.server.map { "\($0):\(proxy.port.map(String.init) ?? "-")" } ?? "-"
            lines.append("  \(proxy.name) = \(proxy.type) \(endpoint) [\(flags.joined(separator: ","))]")
        }
        lines.append("groups (\(profile.groups.count)):")
        for group in profile.groups {
            var extra: [String] = []
            if group.policyPath != nil { extra.append("policy-path") }
            if let filter = group.policyRegexFilter { extra.append("filter=\(filter)") }
            if group.hidden { extra.append("hidden") }
            lines.append("  \(group.name) = \(group.type.rawValue) \(group.members) \(extra.joined(separator: " "))")
        }
        lines.append("rules (\(profile.rules.count)):")
        for (index, rule) in profile.rules.enumerated() {
            var options: [String] = []
            if rule.options.noResolve { options.append("no-resolve") }
            if rule.options.dnsFailed { options.append("dns-failed") }
            if let interval = rule.options.updateInterval { options.append("update-interval=\(Int(interval))") }
            if !rule.isEffective { options.append("ineffective") }
            lines.append(
                "  #\(index + 1) \(rule.condition.typeName) → \(rule.policy ?? "-") \(options.joined(separator: " "))")
        }
        lines.append("hosts (\(profile.hosts.count)): " + profile.hosts.map { "\($0.pattern)" }.joined(separator: ", "))
        lines.append(
            "rewrites: url=\(profile.urlRewrites.count) header=\(profile.headerRewrites.count) body=\(profile.bodyRewrites.count) "
                + "map-local=\(profile.mapLocals.count)")
        lines.append(
            "scripts (\(profile.scripts.count)): "
                + profile.scripts.map { "\($0.name):\($0.type.rawValue)" }.joined(separator: ", "))
        lines.append(
            "mitm: " + profile.mitm.hostnames.map { ($0.isExclusion ? "-" : "") + $0.host }.joined(separator: ", "))
        lines.append("resources (\(profile.externalResources.count)):")
        for resource in profile.externalResources {
            lines.append(
                "  \(resource.kind.rawValue) \(resource.url) interval=\(resource.updateInterval.map { String(Int($0)) } ?? "default")"
            )
        }
        lines.append("diagnostics (\(profile.diagnostics.count)):")
        for diagnostic in profile.diagnostics.sorted(by: {
            ($0.line ?? .max, $0.code.rawValue) < ($1.line ?? .max, $1.code.rawValue)
        }) {
            lines.append("  \(diagnostic.description)")
        }
        lines.append("committable: \(profile.isCommittable)")
        return lines.joined(separator: "\n") + "\n"
    }
}
