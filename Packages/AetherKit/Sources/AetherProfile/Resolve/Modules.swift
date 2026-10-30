import AetherFoundation

/// 模块的输入：文件内容与用户填写的参数值（参数值全局保存，所有配置共用，docs/04 §12.2）。
public struct ModuleInput: Sendable, Equatable {
    /// 用于诊断与展示的名称（通常是模块文件名）。
    public var name: String
    public var text: String
    /// 用户填写的参数值；未填写的参数使用 `#!arguments` 中的默认值。
    public var argumentValues: [String: String]

    public init(name: String, text: String, argumentValues: [String: String] = [:]) {
        self.name = name
        self.text = text
        self.argumentValues = argumentValues
    }
}

/// `#!arguments` 中声明的一个参数。
public struct ModuleArgument: Sendable, Equatable {
    public var name: String
    /// 没有写 `:默认值` 时为 nil。
    public var defaultValue: String?

    public init(name: String, defaultValue: String?) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

/// 模块元数据（docs/04 §12.1）。
public struct ModuleMetadata: Sendable, Equatable {
    public var name: String?
    public var description: String?
    public var author: String?
    public var homepage: String?
    public var icon: String?
    public var category: String?
    public var version: String?
    /// `#!system`，小写；未声明时为 nil。
    public var system: [String]?
    public var arguments: [ModuleArgument] = []
    public var argumentsDescription: String?
    public var requirement: String?

    public init() {}

    /// 读取模块文本的元数据（App 的模块列表与安装确认页使用）。
    public static func parse(text: String, fileName: String) -> (ModuleMetadata, [Diagnostic]) {
        var sink = DiagnosticSink(file: fileName)
        let metadata = parse(ProfileDocument.parse(text, fileName: fileName).0, sink: &sink)
        return (metadata, sink.diagnostics)
    }

    /// 从文件开头的指令读取。
    static func parse(_ document: ProfileDocument, sink: inout DiagnosticSink) -> ModuleMetadata {
        var metadata = ModuleMetadata()
        for (name, value) in document.metadata {
            switch name.lowercased() {
            case "name": metadata.name = value
            case "desc": metadata.description = value
            case "author": metadata.author = value
            case "homepage": metadata.homepage = value
            case "icon": metadata.icon = value
            case "category": metadata.category = value
            case "version": metadata.version = value
            case "system":
                metadata.system = value.split(separator: ",").map { String($0).trimmingWhitespace().lowercased() }
            case "arguments":
                metadata.arguments = parseArguments(value)
            case "arguments-desc": metadata.argumentsDescription = value
            case "requirement":
                metadata.requirement = value
                sink.report(.cfgModuleRequirementIgnored, line: nil, arguments: [value], "#!requirement is ignored")
            default:
                sink.report(.cfgUnknownKey, line: nil, arguments: ["#!" + name], "Unknown module directive #!\(name)")
            }
        }
        if metadata.name?.isEmpty ?? true {
            sink.report(.cfgModuleMissingName, line: nil, "Module has no #!name; the file name is shown instead")
        }
        if let system = metadata.system, !system.contains("ios") {
            sink.report(
                .cfgModuleSystemMismatch, line: nil, arguments: [system.joined(separator: ",")],
                "Module declares #!system=\(system.joined(separator: ",")) without ios; it can still be enabled")
        }
        return metadata
    }

    /// `名:默认值` 逗号分隔；默认值可以为空串（`名:`），也可以没有（`名`）。
    static func parseArguments(_ text: String) -> [ModuleArgument] {
        ValueParser.list(text).compactMap { item in
            if let colon = item.firstIndex(of: ":") {
                let name = String(item[..<colon]).trimmingWhitespace()
                guard !name.isEmpty else { return nil }
                return ModuleArgument(name: name, defaultValue: String(item[colon...].dropFirst()).trimmingWhitespace())
            }
            return item.isEmpty ? nil : ModuleArgument(name: item, defaultValue: nil)
        }
    }
}

extension AetherErrorCode {
    /// 模块声明的 `#!system` 不含 iOS。
    public static let cfgModuleSystemMismatch: AetherErrorCode = "CFG-083"
    /// 模块缺少 `#!name`。
    public static let cfgModuleMissingName: AetherErrorCode = "CFG-084"
}

extension ModuleInput {
    /// 参数值代入后的模块文本（运行包中保存的形式，docs/11 §6）；有占位符没有值时为 nil（该模块不能提交）。
    public func substitutedText() -> String? {
        var sink = DiagnosticSink(file: name)
        let (document, _) = ProfileDocument.parse(text, fileName: name)
        let metadata = ModuleMetadata.parse(document, sink: &sink)
        return ModuleArgumentSubstitution.substitute(
            text, arguments: metadata.arguments, values: argumentValues, sink: &sink)
    }
}

/// 模块参数替换：把正文中的 `{{{名}}}` 替换为参数值（用户值优先，其次默认值）。
enum ModuleArgumentSubstitution {
    /// - Returns: 替换后的文本；声明了但没有值、或未声明的占位符报告 `CFG-081` 并返回 nil。
    static func substitute(
        _ text: String, arguments: [ModuleArgument], values: [String: String], sink: inout DiagnosticSink
    ) -> String? {
        var resolved: [String: String] = [:]
        for argument in arguments {
            if let value = values[argument.name] ?? argument.defaultValue {
                // 值中的换行会破坏行号与条目结构，替换为空格。
                resolved[argument.name] = value.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(
                    of: "\n", with: " ")
            }
        }
        var output = ""
        var remainder = Substring(text)
        var ok = true
        while let open = remainder.range(of: "{{{") {
            output += remainder[..<open.lowerBound]
            let afterOpen = remainder[open.upperBound...]
            guard let close = afterOpen.range(of: "}}}") else {
                output += remainder[open.lowerBound...]
                remainder = ""
                break
            }
            let name = String(afterOpen[..<close.lowerBound])
            if let value = resolved[name] {
                output += value
            } else {
                ok = false
                let line = text[..<open.lowerBound].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
                let declared = arguments.contains { $0.name == name }
                sink.report(
                    .cfgModuleArgumentMissing, line: line, arguments: [name],
                    declared
                        ? "Module argument \(name) has no value and no default"
                        : "Module uses undeclared argument \(name)")
                output += remainder[open.lowerBound..<close.upperBound]
            }
            remainder = afterOpen[close.upperBound...]
        }
        output += remainder
        return ok ? output : nil
    }
}

/// `[General]` / `[MITM]` 的叠加（docs/04 §12.2）：`键 = 值` 替换；`%APPEND%` 追加；`%INSERT%` 插入开头。
enum KeyedOverlay {
    /// - Parameters:
    ///   - layers: 从低优先级到高优先级的条目序列（配置在最前，排在模块列表末尾的模块其次，第一个模块最后）。
    ///   - defaultList: 列表键的默认值文本，供第一次 `%APPEND%` / `%INSERT%` 使用。
    static func apply(_ layers: [[KeyedEntry]], defaultList: (String) -> String?) -> [KeyedEntry] {
        var order: [String] = []
        var state: [String: KeyedEntry] = [:]
        for layer in layers {
            for entry in layer {
                let current = state[entry.key]?.value ?? defaultList(entry.key) ?? ""
                var value = entry.value
                if value.hasPrefix("%APPEND%") {
                    let addition = String(value.dropFirst("%APPEND%".count)).trimmingWhitespace()
                    value = current.isEmpty ? addition : (addition.isEmpty ? current : current + ", " + addition)
                } else if value.hasPrefix("%INSERT%") {
                    let addition = String(value.dropFirst("%INSERT%".count)).trimmingWhitespace()
                    value = current.isEmpty ? addition : (addition.isEmpty ? current : addition + ", " + current)
                }
                if state[entry.key] == nil { order.append(entry.key) }
                state[entry.key] = KeyedEntry(key: entry.key, value: value, source: entry.source)
            }
        }
        return order.compactMap { state[$0] }
    }
}

extension GeneralSettings {
    /// 内置的真实 IP 例外表（docs/07 §3.3）。
    public static let builtinAlwaysRealIP = [
        "*.lan", "*.local", "*.localdomain", "*.home.arpa", "localhost", "captive.apple.com", "time.apple.com",
        "time-ios.apple.com", "*.ntp.org", "stun.*",
    ]

    /// 列表键的默认值文本，供模块 `%APPEND%` / `%INSERT%` 在其上增补。
    static func defaultListText(for key: String) -> String? {
        switch key {
        case "skip-proxy": return defaultSkipProxy.joined(separator: ", ")
        case "always-real-ip": return builtinAlwaysRealIP.joined(separator: ", ")
        case "hijack-dns": return "*:53"
        case "dns-server": return "system"
        default: return nil
        }
    }
}
