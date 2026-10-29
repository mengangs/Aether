import AetherFoundation
import Foundation

/// 解析过程中收集诊断。
struct DiagnosticSink {
    let file: String
    var diagnostics: [Diagnostic] = []

    mutating func report(
        _ code: AetherErrorCode, line: Int?, column: Int? = nil, arguments: [String] = [], _ message: String
    ) {
        diagnostics.append(
            Diagnostic(code, file: file, line: line, column: column, arguments: arguments, message: message))
    }
}

/// 值语法（docs/04 §3.2）。
enum ValueParser {
    /// `true` / `false`，也接受 `1` / `0`、`yes` / `no`、`on` / `off`。
    static func bool(_ text: String) -> Bool? {
        switch text.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }

    /// 秒：非负有限的整数或小数。
    static func seconds(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite, value >= 0, !text.contains("e"), !text.contains("E") else {
            return nil
        }
        return value
    }

    static func integer(_ text: String, in range: ClosedRange<Int>) -> Int? {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }), text.count <= 10, let value = Int(text),
            range.contains(value)
        else { return nil }
        return value
    }

    /// 端口或闭区间 `起-止`（1–65535）。
    static func portRange(_ text: String) -> ClosedRange<UInt16>? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        guard let lower = integer(String(parts[0]).trimmingWhitespace(), in: 1...65535) else { return nil }
        let upper = parts.count == 2 ? integer(String(parts[1]).trimmingWhitespace(), in: 1...65535) : lower
        guard let upper, lower <= upper else { return nil }
        return UInt16(lower)...UInt16(upper)
    }

    /// ICU 正则是否有效（`NSRegularExpression`，两个平台一致）。
    static func isValidRegex(_ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }

    /// 逗号分隔的列表值（[General] 中的列表）。
    static func list(_ text: String) -> [String] {
        guard case .success(let fields) = FieldTokenizer.split(text) else {
            return text.split(separator: ",").map { String($0).trimmingWhitespace() }.filter { !$0.isEmpty }
        }
        return fields.map(\.value).filter { !$0.isEmpty }
    }

    /// 外部资源地址：`http://`、`https://` 或本地相对路径。
    enum ResourceCheck: Equatable {
        case ok
        /// HTTP 资源：允许但警告（`CFG-090`）。
        case insecure
        /// 无效（`CFG-091`）。
        case invalid
    }

    static func checkResource(_ text: String) -> ResourceCheck {
        let lower = text.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            guard let components = URLComponents(string: text), let host = components.host, !host.isEmpty else {
                return .invalid
            }
            return lower.hasPrefix("http://") ? .insecure : .ok
        }
        if text.isEmpty || text.contains("://") || text.hasPrefix("/") || text.split(separator: "/").contains("..") {
            return .invalid
        }
        return .ok
    }

    /// 通配模式是否合法：非空、不含空白与逗号。
    static func isValidWildcard(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.contains { $0.properties.isWhitespace || $0 == "," }
    }

    /// `IP[:端口]`、`[IPv6]:端口` 或 `*:端口`。
    static func hostPort(_ text: String, allowWildcard: Bool) -> Bool {
        var host = Substring(text)
        var port: Substring?
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { return false }
            let rest = host[host.index(after: close)...]
            host = host[host.index(after: host.startIndex)..<close]
            if !rest.isEmpty {
                guard rest.hasPrefix(":") else { return false }
                port = rest.dropFirst()
            }
        } else if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
            port = host[host.index(after: colon)...]
            host = host[..<colon]
        }
        if let port, integer(String(port), in: 1...65535) == nil { return false }
        if allowWildcard, host == "*" { return port != nil }
        return IPAddress(host) != nil
    }
}

/// `[General]`、`[MITM]` 的一个原始键值（叠加之前）。
public struct KeyedEntry: Sendable, Equatable {
    /// 小写键名。
    public var key: String
    public var value: String
    public var source: SourceReference

    public init(key: String, value: String, source: SourceReference) {
        self.key = key
        self.value = value
        self.source = source
    }
}
