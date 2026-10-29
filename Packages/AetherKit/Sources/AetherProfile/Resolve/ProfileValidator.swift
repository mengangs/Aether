import AetherFoundation

/// 跨条目的语义校验（docs/04 §13，M1-04）：策略名唯一、引用存在、组循环、组成员来源、FINAL。
enum ProfileValidator {
    /// 策略名表：节点与组（区分大小写），以及内置策略（不区分大小写）。
    struct PolicyNames {
        var proxies: Set<String>
        var groups: Set<String>

        func contains(_ name: String) -> Bool {
            BuiltinPolicy(name: name) != nil || proxies.contains(name) || groups.contains(name)
        }
    }

    /// 校验节点与组的命名，返回可引用的策略名表。
    static func checkNames(proxies: [ProxySpec], groups: [PolicyGroupSpec], sink: inout DiagnosticSink) -> PolicyNames {
        var seen: [String: SourceReference] = [:]
        func check(_ name: String, _ source: SourceReference) {
            if BuiltinPolicy(name: name) != nil {
                sink.report(
                    .cfgDuplicatePolicy, line: source.line, arguments: [name],
                    "\(name) conflicts with a built-in policy name")
            } else if let previous = seen[name] {
                sink.report(
                    .cfgDuplicatePolicy, line: source.line, arguments: [name, String(previous.line)],
                    "Policy name \(name) is already used at line \(previous.line)")
            } else {
                seen[name] = source
            }
        }
        for proxy in proxies { check(proxy.name, proxy.source) }
        for group in groups { check(group.name, group.source) }
        return PolicyNames(proxies: Set(proxies.map(\.name)), groups: Set(groups.map(\.name)))
    }

    /// 组：成员与 include-other-group 引用存在（`CFG-011`）、有成员来源（`CFG-013`）、无环（`CFG-012`）。
    static func checkGroups(_ groups: [PolicyGroupSpec], names: PolicyNames, sink: inout DiagnosticSink) {
        for group in groups {
            for member in group.members where !names.contains(member) {
                sink.report(
                    .cfgUnknownPolicy, line: group.source.line, arguments: [group.name, member],
                    "Group \(group.name) references unknown policy \(member)")
            }
            for other in group.includeOtherGroups where !names.groups.contains(other) {
                sink.report(
                    .cfgUnknownPolicy, line: group.source.line, arguments: [group.name, other],
                    "Group \(group.name) includes unknown group \(other)")
            }
            if !group.hasMemberSource {
                sink.report(
                    .cfgGroupWithoutMembers, line: group.source.line, arguments: [group.name],
                    "Group \(group.name) has no members")
            }
        }
        // 组 → 组的边（显式成员与 include-other-group）。
        let byName = Dictionary(groups.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var edges: [String: [String]] = [:]
        for group in groups {
            edges[group.name] = (group.members + group.includeOtherGroups).filter { byName[$0] != nil }
        }
        var state: [String: Int] = [:]  // 0 未访问，1 在栈上，2 完成
        var reported: Set<String> = []
        func visit(_ name: String, path: [String]) {
            state[name] = 1
            for next in edges[name] ?? [] {
                if state[next] == 1 {
                    let cycle = Array(path[(path.firstIndex(of: next) ?? 0)...]) + [next]
                    let key = Set(cycle).sorted().joined(separator: "\u{1}")
                    if reported.insert(key).inserted, let group = byName[next] {
                        sink.report(
                            .cfgGroupCycle, line: group.source.line, arguments: [cycle.joined(separator: " → ")],
                            "Policy groups form a cycle: \(cycle.joined(separator: " → "))")
                    }
                } else if state[next, default: 0] == 0 {
                    visit(next, path: path + [next])
                }
            }
            state[name] = 2
        }
        for group in groups where state[group.name, default: 0] == 0 {
            visit(group.name, path: [group.name])
        }
    }

    /// 规则的策略引用（`CFG-011`）。
    static func checkRulePolicies(_ rules: [RuleSpec], names: PolicyNames, sink: inout DiagnosticSink) -> Bool {
        var ok = true
        for rule in rules {
            guard let policy = rule.policy, !names.contains(policy) else { continue }
            ok = false
            var local = DiagnosticSink(file: rule.source.file)
            local.report(
                .cfgUnknownPolicy, line: rule.source.line, arguments: [policy],
                "Rule references unknown policy \(policy)")
            sink.diagnostics += local.diagnostics
        }
        return ok
    }

    /// FINAL：缺失时隐式追加 `FINAL,DIRECT`（`CFG-035`）；其后的规则不会被匹配（`CFG-036`）并从结果中移除。
    static func finalizeRules(_ rules: [RuleSpec], file: String, sink: inout DiagnosticSink) -> [RuleSpec] {
        guard let finalIndex = rules.firstIndex(where: { $0.condition == .final }) else {
            sink.report(.cfgMissingFinal, line: nil, "No FINAL rule; FINAL,DIRECT is appended")
            let implicit = RuleSpec(
                condition: .final, policy: BuiltinPolicy.direct.rawValue, raw: "FINAL,DIRECT",
                source: SourceReference(file: file, line: 0, raw: "FINAL,DIRECT"))
            return rules + [implicit]
        }
        for rule in rules[(finalIndex + 1)...] {
            var local = DiagnosticSink(file: rule.source.file)
            local.report(
                .cfgRuleAfterFinal, line: rule.source.line, arguments: [rule.raw], "Rule after FINAL never matches")
            sink.diagnostics += local.diagnostics
        }
        return Array(rules[...finalIndex])
    }
}
