// 架构约束检查（docs/02-architecture.md §3.2、CLAUDE.md「代码约定」）。
//
// 用法：swift Scripts/check-architecture.swift [仓库根目录]
//
// 检查项：
// 1. AetherKit 中每个模块的直接依赖都在 02 §3.2 允许的依赖闭包内（不得反向依赖、不得出现未登记的模块）；
// 2. 跨平台模块的源码不得 import Apple 专有框架；
// 3. project.yml 中 App 与小组件 target 不得直接或间接依赖 AetherEngine、AetherOutbound、AetherHTTP。
//
// 在 Linux 上 dump-package 不包含 Apple 专有模块，因此第 1 项在 macOS 上运行时覆盖更完整。

import Foundation

/// 02 §3.2 的依赖图：模块 → 允许直接依赖的 AetherKit 模块。新增模块必须先登记在这里与文档中。
let allowedGraph: [String: [String]] = [
    "AetherFoundation": [],
    "AetherProfile": ["AetherFoundation"],
    "AetherRules": ["AetherFoundation"],
    "AetherDNS": ["AetherFoundation"],
    "AetherOutbound": ["AetherFoundation", "CBlake3"],
    "AetherCertificates": ["AetherFoundation"],
    "AetherScriptCore": ["AetherFoundation"],
    "AetherHTTP": ["AetherOutbound", "AetherRules", "AetherCertificates", "AetherScriptCore"],
    "AetherIPC": ["AetherFoundation"],
    "AetherStore": ["AetherFoundation"],
    "AetherEngine": ["AetherProfile", "AetherRules", "AetherDNS", "AetherHTTP", "AetherIPC", "AetherStore"],
    "AetherScript": ["AetherScriptCore"],
    "AetherControl": ["AetherIPC"],
    "AetherTunnelSupport": ["AetherEngine", "CHevSocks5Tunnel"],
    "aether-cli": ["AetherEngine"],
    "CBlake3": [],
    "CHevSocks5Tunnel": [],
]

/// 只能在 Apple 平台编译的模块；其余模块都必须跨平台。
let appleOnlyModules: Set<String> = [
    "AetherScript", "AetherControl", "AetherTunnelSupport", "CHevSocks5Tunnel",
]

/// 跨平台模块不得 import 的框架。
let forbiddenFrameworks = [
    "UIKit", "SwiftUI", "NetworkExtension", "JavaScriptCore", "CryptoKit", "Network", "Security",
]

/// App 与小组件不得直接或间接依赖的模块。
let appForbiddenModules: Set<String> = ["AetherEngine", "AetherOutbound", "AetherHTTP"]

var failures: [String] = []

func closure(of module: String) -> Set<String> {
    var seen: Set<String> = []
    var stack = allowedGraph[module] ?? []
    while let next = stack.popLast() {
        if seen.insert(next).inserted {
            stack.append(contentsOf: allowedGraph[next] ?? [])
        }
    }
    return seen
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let packageDir = root.appendingPathComponent("Packages/AetherKit")

// MARK: 1. 依赖方向

func dumpPackage() -> [String: Any]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "package", "--package-path", packageDir.path, "dump-package"]
    let pipe = Pipe()
    process.standardOutput = pipe
    do {
        try process.run()
    } catch {
        failures.append("无法运行 swift package dump-package：\(error)")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        failures.append("swift package dump-package 失败（退出码 \(process.terminationStatus)）")
        return nil
    }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

/// 解析 dump-package 中的依赖项，只返回包内 target 依赖。
func internalDependencies(_ target: [String: Any], targetNames: Set<String>) -> [String] {
    let deps = target["dependencies"] as? [[String: Any]] ?? []
    return deps.compactMap { dep -> String? in
        if let byName = dep["byName"] as? [Any], let name = byName.first as? String, targetNames.contains(name) {
            return name
        }
        if let target = dep["target"] as? [Any], let name = target.first as? String {
            return name
        }
        return nil
    }
}

var packageTargets: [String] = []
if let manifest = dumpPackage(), let targets = manifest["targets"] as? [[String: Any]] {
    let names = Set(targets.compactMap { $0["name"] as? String })
    for target in targets {
        guard let name = target["name"] as? String, let type = target["type"] as? String else { continue }
        if type == "test" { continue }
        packageTargets.append(name)
        guard allowedGraph[name] != nil else {
            failures.append("模块 \(name) 未登记在 02 §3 与本脚本的依赖图中")
            continue
        }
        let allowed = closure(of: name)
        for dep in internalDependencies(target, targetNames: names) where !allowed.contains(dep) {
            failures.append("\(name) 不得依赖 \(dep)（违反 02 §3.2 的依赖方向）")
        }
    }
}

// MARK: 2. 跨平台模块的 import

let fileManager = FileManager.default
for module in packageTargets where !appleOnlyModules.contains(module) {
    let dir = packageDir.appendingPathComponent("Sources/\(module)")
    guard let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
    for case let file as URL in enumerator where file.pathExtension == "swift" {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let importIndex = words.firstIndex(of: "import"), importIndex + 1 < words.count else { continue }
            guard
                words[..<importIndex].allSatisfy({
                    $0.hasPrefix("@") || ["public", "internal", "package"].contains($0)
                })
            else { continue }
            let imported = words[importIndex + 1].split(separator: ".").first.map(String.init) ?? ""
            if forbiddenFrameworks.contains(imported) {
                failures.append("\(file.path):\(index + 1)：跨平台模块 \(module) 不得 import \(imported)")
            }
        }
    }
}

// MARK: 3. App 与小组件的依赖

let projectFile = root.appendingPathComponent("project.yml")
if let project = try? String(contentsOf: projectFile, encoding: .utf8) {
    // 只解析 project.yml 中 `targets:` 下各 target 的 `products: [...]` 行，足以覆盖本仓库的写法。
    var currentTarget: String?
    var inTargets = false
    for rawLine in project.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = String(rawLine)
        if line.hasPrefix("targets:") {
            inTargets = true
            continue
        }
        if !line.hasPrefix(" "), !line.isEmpty, !line.hasPrefix("#") {
            inTargets = false
        }
        guard inTargets else { continue }
        if line.hasPrefix("  "), !line.hasPrefix("   "), line.hasSuffix(":") {
            currentTarget = line.trimmingCharacters(in: .whitespaces).dropLast().description
            continue
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let target = currentTarget, trimmed.hasPrefix("products:"),
            let open = trimmed.firstIndex(of: "["), let close = trimmed.firstIndex(of: "]")
        else { continue }
        let products = trimmed[trimmed.index(after: open)..<close].split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let isAppSide = target == "Aether" || target.hasPrefix("AetherWidget")
        guard isAppSide else { continue }
        for product in products {
            let reachable = closure(of: product).union([product])
            let bad = reachable.intersection(appForbiddenModules)
            if !bad.isEmpty {
                failures.append("project.yml：\(target) 依赖 \(product)，间接引入 \(bad.sorted().joined(separator: "、"))")
            }
        }
    }
}

if failures.isEmpty {
    print("架构检查通过：\(packageTargets.count) 个模块。")
} else {
    for failure in failures {
        print("error: \(failure)")
    }
    exit(1)
}
