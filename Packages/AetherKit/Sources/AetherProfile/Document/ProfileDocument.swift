import AetherFoundation
import Foundation

/// 行在文档中的稳定标识，编辑期间不变（docs/04 §15.1）。
public struct LineID: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (lhs: LineID, rhs: LineID) -> Bool { lhs.rawValue < rhs.rawValue }
    public var description: String { "L\(rawValue)" }
}

/// 换行风格。
public enum LineEnding: String, Sendable {
    case lf = "\n"
    case crlf = "\r\n"
}

/// 已知的节（docs/04 §4–§11）。节名匹配不区分大小写、忽略首尾空白。
public enum ProfileSection: String, CaseIterable, Sendable {
    case general = "general"
    case proxy = "proxy"
    case proxyGroup = "proxy group"
    case rule = "rule"
    case host = "host"
    case urlRewrite = "url rewrite"
    case headerRewrite = "header rewrite"
    case bodyRewrite = "body rewrite"
    case mapLocal = "map local"
    case script = "script"
    case mitm = "mitm"

    public init?(name: String) {
        self.init(rawValue: ProfileSection.normalize(name))
    }

    /// 规范化节名：去首尾空白、小写、内部连续空白合并为一个空格。
    public static func normalize(_ name: String) -> String {
        name.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// 条目是否为 `键 = 值` 形式（其余节整行为一个值）。
    public var isKeyed: Bool {
        switch self {
        case .general, .proxy, .proxyGroup, .host, .script, .mitm: return true
        case .rule, .urlRewrite, .headerRewrite, .bodyRewrite, .mapLocal: return false
        }
    }
}

/// 节内条目。键值节中 `key` 为 `=` 左侧（去首尾空白），`value` 为右侧（去首尾空白）；其它节 `key` 为 nil。
public struct ProfileEntry: Sendable, Hashable {
    public var key: String?
    public var value: String
    /// `value` 在原文行中的起始列（1 起，按 Unicode 标量计），用于诊断定位。
    public var valueColumn: Int

    public init(key: String?, value: String, valueColumn: Int) {
        self.key = key
        self.value = value
        self.valueColumn = valueColumn
    }
}

/// 一行的分类。
public enum ProfileLineKind: Sendable, Hashable {
    case blank
    case comment
    /// `#!名称=值` 或 `#!名称 值`。
    case directive(name: String, value: String)
    /// `[名称]`，名称保留原拼写（去首尾空白）。
    case sectionHeader(name: String)
    case entry(ProfileEntry)
    /// 语法错误的行，原文保留（`CFG-004`）。
    case invalid(reason: String)
}

/// 无损语法树中的一行（docs/04 §15.1）。
public struct ProfileLine: Sendable, Identifiable, Hashable {
    public let id: LineID
    /// 行内容，不含换行符。
    public var raw: String
    /// 原换行符：`\n`、`\r\n`，最后一行没有换行时为空串。
    public var terminator: String
    public var kind: ProfileLineKind
    /// 所属节的规范化名（`ProfileSection.normalize`）；第一个节标题之前为 nil。
    public var sectionName: String?
    /// 行号（1 起）。编辑后由 `ProfileDocument` 重新编号。
    public var lineNumber: Int

    public var section: ProfileSection? { sectionName.flatMap { ProfileSection(rawValue: $0) } }
}

/// 无损语法树：保留每一行的原文、位置和分类（docs/04 §2、§15.1）。未修改时 `render()` 与输入逐字节一致。
public struct ProfileDocument: Sendable, Equatable {
    public internal(set) var lines: [ProfileLine]
    /// 主要换行风格（新增行使用）：取第一个换行符的风格，没有换行时为 LF。
    public var lineEnding: LineEnding
    public var hasBOM: Bool
    /// 文件名（配置或模块名），用于诊断。
    public var fileName: String

    var nextLineID: Int

    /// 文件开头的指令（元数据），如 `#!MANAGED-CONFIG`、模块的 `#!name`。
    public var metadata: [(name: String, value: String)] {
        var result: [(String, String)] = []
        for line in lines {
            switch line.kind {
            case .directive(let name, let value): result.append((name, value))
            case .blank, .comment: continue
            default: return result
            }
        }
        return result
    }

    public static func == (lhs: ProfileDocument, rhs: ProfileDocument) -> Bool {
        lhs.lines == rhs.lines && lhs.lineEnding == rhs.lineEnding && lhs.hasBOM == rhs.hasBOM
            && lhs.fileName == rhs.fileName
    }

    // MARK: - 解析

    /// 从字节解析；不是有效 UTF-8 时返回 nil 与 `CFG-001`。
    public static func parse(data: Data, fileName: String) -> (ProfileDocument?, [Diagnostic]) {
        // Foundation 解码时会静默去掉 BOM，这里先识别再解码其余字节，保证渲染时能原样写回。
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let hasBOM = data.starts(with: bom)
        let payload = hasBOM ? data.dropFirst(bom.count) : data[...]
        guard let decoded = String(data: Data(payload), encoding: .utf8) else {
            return (
                nil,
                [Diagnostic(.cfgUndecodable, file: fileName, message: "The file is not valid UTF-8")]
            )
        }
        let (document, diagnostics) = parse(hasBOM ? "\u{FEFF}" + decoded : decoded, fileName: fileName)
        return (document, diagnostics)
    }

    /// 解析文本。任何输入都不会崩溃；语法错误的行保留原文并给出诊断。
    public static func parse(_ text: String, fileName: String) -> (ProfileDocument, [Diagnostic]) {
        var body = Substring(text)
        var hasBOM = false
        if body.unicodeScalars.first == "\u{FEFF}" {
            hasBOM = true
            body = Substring(body.unicodeScalars.dropFirst())
        }

        var document = ProfileDocument(
            lines: [], lineEnding: .lf, hasBOM: hasBOM, fileName: fileName, nextLineID: 0)
        var diagnostics: [Diagnostic] = []
        var section: String?
        var seenContent = false
        var firstEnding: LineEnding?

        let utf8 = body.utf8
        var start = utf8.startIndex
        var lineNumber = 0
        while start < utf8.endIndex || (start == utf8.endIndex && lineNumber == 0 && !utf8.isEmpty) {
            lineNumber += 1
            var end = start
            while end < utf8.endIndex, utf8[end] != UInt8(ascii: "\n") {
                end = utf8.index(after: end)
            }
            var contentEnd = end
            var terminator = ""
            if end < utf8.endIndex {
                if contentEnd > start, utf8[utf8.index(before: contentEnd)] == UInt8(ascii: "\r") {
                    contentEnd = utf8.index(before: contentEnd)
                    terminator = "\r\n"
                } else {
                    terminator = "\n"
                }
            }
            if firstEnding == nil, !terminator.isEmpty {
                firstEnding = terminator == "\r\n" ? .crlf : .lf
            }
            let raw = String(decoding: utf8[start..<contentEnd], as: UTF8.self)
            let (kind, lineDiagnostics) = classify(
                raw, section: section, seenContent: seenContent, file: fileName, line: lineNumber)
            diagnostics += lineDiagnostics
            switch kind {
            case .sectionHeader(let name):
                section = ProfileSection.normalize(name)
                seenContent = true
            case .entry, .invalid:
                seenContent = true
            case .directive, .blank, .comment:
                break
            }
            document.appendParsed(
                raw: raw, terminator: terminator, kind: kind, section: section, lineNumber: lineNumber)
            start = end < utf8.endIndex ? utf8.index(after: end) : utf8.endIndex
            if end == utf8.endIndex { break }
        }
        document.lineEnding = firstEnding ?? .lf
        return (document, diagnostics)
    }

    /// 按所在节对一行分类。
    static func classify(_ raw: String, section: String?, seenContent: Bool, file: String, line: Int)
        -> (ProfileLineKind, [Diagnostic])
    {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return (.blank, [])
        }
        if trimmed.hasPrefix("#!") {
            let body = trimmed.dropFirst(2)
            let nameEnd = body.firstIndex(where: { $0 == "=" || $0 == " " || $0 == "\t" }) ?? body.endIndex
            let name = String(body[..<nameEnd])
            var value = body[nameEnd...]
            if value.first == "=" { value = value.dropFirst() }
            let kind = ProfileLineKind.directive(name: name, value: value.trimmingCharacters(in: .whitespaces))
            if seenContent {
                return (
                    kind,
                    [
                        Diagnostic(
                            .cfgUnknownKey, file: file, line: line, arguments: [name],
                            message: "Directive #!\(name) is only meaningful at the top of the file")
                    ]
                )
            }
            return (kind, [])
        }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") || trimmed.hasPrefix("//") {
            return (.comment, [])
        }
        if trimmed.hasPrefix("[") {
            guard trimmed.hasSuffix("]"), trimmed.count >= 2 else {
                return (
                    .invalid(reason: "unterminated section header"),
                    [Diagnostic(.cfgSyntax, file: file, line: line, message: "Section header is missing ']'")]
                )
            }
            let name = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
            return (.sectionHeader(name: name), [])
        }
        guard let section else {
            return (
                .invalid(reason: "entry outside of any section"),
                [Diagnostic(.cfgSyntax, file: file, line: line, message: "Entry appears before the first section")]
            )
        }
        let leading = raw.unicodeScalars.prefix { $0 == " " || $0 == "\t" }.count
        if let known = ProfileSection(rawValue: section), known.isKeyed {
            guard let equals = trimmed.firstIndex(of: "=") else {
                return (
                    .invalid(reason: "missing '='"),
                    [Diagnostic(.cfgSyntax, file: file, line: line, message: "Expected 'key = value'")]
                )
            }
            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            let afterEquals = trimmed[trimmed.index(after: equals)...]
            let valueLeading = afterEquals.unicodeScalars.prefix { $0 == " " || $0 == "\t" }.count
            let value = afterEquals.trimmingCharacters(in: .whitespaces)
            let column = leading + trimmed[..<equals].unicodeScalars.count + 1 + valueLeading + 1
            guard !key.isEmpty else {
                return (
                    .invalid(reason: "empty key"),
                    [Diagnostic(.cfgSyntax, file: file, line: line, message: "Missing key before '='")]
                )
            }
            return (.entry(ProfileEntry(key: key, value: value, valueColumn: column)), [])
        }
        return (.entry(ProfileEntry(key: nil, value: trimmed, valueColumn: leading + 1)), [])
    }

    mutating func appendParsed(
        raw: String, terminator: String, kind: ProfileLineKind, section: String?, lineNumber: Int
    ) {
        lines.append(
            ProfileLine(
                id: LineID(nextLineID), raw: raw, terminator: terminator, kind: kind, sectionName: section,
                lineNumber: lineNumber))
        nextLineID += 1
    }

    // MARK: - 渲染

    /// 渲染为文本。未修改的文档与输入逐字节一致。
    public func render() -> String {
        var output = hasBOM ? "\u{FEFF}" : ""
        output.reserveCapacity(lines.reduce(0) { $0 + $1.raw.utf8.count + 2 })
        for line in lines {
            output += line.raw
            output += line.terminator
        }
        return output
    }

    // MARK: - 查询

    /// 某节（规范化名）中的条目行，按文件顺序（同名节合并，docs/04 §2）。
    public func entries(in section: ProfileSection) -> [ProfileLine] {
        lines.filter {
            guard case .entry = $0.kind else { return false }
            return $0.sectionName == section.rawValue
        }
    }

    /// 文件中出现的全部节名（规范化名，去重，保持首次出现顺序）。
    public var sectionNames: [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for line in lines {
            if case .sectionHeader(let name) = line.kind {
                let normalized = ProfileSection.normalize(name)
                if seen.insert(normalized).inserted { result.append(normalized) }
            }
        }
        return result
    }

    public func line(_ id: LineID) -> ProfileLine? {
        lines.first { $0.id == id }
    }
}
