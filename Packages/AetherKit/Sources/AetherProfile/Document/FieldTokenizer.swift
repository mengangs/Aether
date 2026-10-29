/// 逗号分隔字段的分词器（docs/04 §3.1、§7.3）：识别引号字段（`\"`、`\\` 转义）与括号深度，
/// **不得**用 `split(",")` 代替。
public enum FieldTokenizer {
    /// 一个字段。
    public struct Field: Sendable, Hashable {
        /// 原文（已去首尾空白，引号字段含引号）。
        public var raw: String
        /// 值：引号字段去掉引号并处理转义，否则同 `raw`。
        public var value: String
        public var isQuoted: Bool
        /// 在输入中的起始列（0 起，按 Unicode 标量）。
        public var offset: Int
    }

    public enum TokenizeError: Error, Equatable, Sendable {
        case unterminatedQuote(offset: Int)
        case unbalancedParentheses(offset: Int)
    }

    /// 按 `separator` 切分。括号内（深度 > 0）的分隔符不切分。
    public static func split(_ text: some StringProtocol, separator: Unicode.Scalar = ",") -> Result<
        [Field], TokenizeError
    > {
        var fields: [Field] = []
        var current: [Unicode.Scalar] = []
        var currentStart = 0
        var depth = 0
        var inQuote = false
        var quoteStart = 0
        var escaped = false
        var index = 0
        for scalar in text.unicodeScalars {
            defer { index += 1 }
            if inQuote {
                current.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inQuote = false
                }
                continue
            }
            switch scalar {
            case "\"":
                inQuote = true
                quoteStart = index
                current.append(scalar)
            case "(":
                depth += 1
                current.append(scalar)
            case ")":
                depth -= 1
                if depth < 0 { return .failure(.unbalancedParentheses(offset: index)) }
                current.append(scalar)
            case separator where depth == 0:
                fields.append(makeField(current, start: currentStart))
                current = []
                currentStart = index + 1
            default:
                current.append(scalar)
            }
        }
        if inQuote { return .failure(.unterminatedQuote(offset: quoteStart)) }
        if depth != 0 { return .failure(.unbalancedParentheses(offset: index)) }
        fields.append(makeField(current, start: currentStart))
        return .success(fields)
    }

    /// 按空白切分（重写类节），引号字段可含空白。
    public static func splitWhitespace(_ text: some StringProtocol) -> Result<[Field], TokenizeError> {
        var fields: [Field] = []
        var current: [Unicode.Scalar] = []
        var currentStart = 0
        var inQuote = false
        var quoteStart = 0
        var escaped = false
        var index = 0
        for scalar in text.unicodeScalars {
            defer { index += 1 }
            if inQuote {
                current.append(scalar)
                if escaped {
                    escaped = false
                } else if scalar == "\\" {
                    escaped = true
                } else if scalar == "\"" {
                    inQuote = false
                }
                continue
            }
            if scalar == " " || scalar == "\t" {
                if !current.isEmpty {
                    fields.append(makeField(current, start: currentStart))
                    current = []
                }
                currentStart = index + 1
                continue
            }
            if scalar == "\"" {
                inQuote = true
                quoteStart = index
            }
            if current.isEmpty { currentStart = index }
            current.append(scalar)
        }
        if inQuote { return .failure(.unterminatedQuote(offset: quoteStart)) }
        if !current.isEmpty { fields.append(makeField(current, start: currentStart)) }
        return .success(fields)
    }

    static func makeField(_ scalars: [Unicode.Scalar], start: Int) -> Field {
        var raw = String(String.UnicodeScalarView(scalars))
        let leading = raw.unicodeScalars.prefix { $0 == " " || $0 == "\t" }.count
        raw = raw.trimmingWhitespace()
        if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.unicodeScalars.count >= 2 {
            return Field(raw: raw, value: unquote(raw), isQuoted: true, offset: start + leading)
        }
        return Field(raw: raw, value: raw, isQuoted: false, offset: start + leading)
    }

    /// 去掉外层引号并处理 `\"`、`\\`；其它反斜杠序列原样保留（正则中的 `\.` 等）。
    public static func unquote(_ quoted: String) -> String {
        let inner = quoted.unicodeScalars.dropFirst().dropLast()
        var result = String.UnicodeScalarView()
        var escaped = false
        for scalar in inner {
            if escaped {
                if scalar != "\"" && scalar != "\\" { result.append("\\") }
                result.append(scalar)
                escaped = false
            } else if scalar == "\\" {
                escaped = true
            } else {
                result.append(scalar)
            }
        }
        if escaped { result.append("\\") }
        return String(result)
    }

    /// 需要时给值加引号（含逗号、引号或首尾空白）。
    public static func quoteIfNeeded(_ value: String) -> String {
        let needs = value.contains(",") || value.contains("\"") || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needs else { return value }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// 解析 `key=value` 字段：键去空白、小写；值可为引号字段。没有 `=` 返回 nil。
    public static func keyValue(_ field: Field) -> (key: String, value: String)? {
        guard !field.isQuoted, let equals = field.raw.firstIndex(of: "=") else { return nil }
        let key = field.raw[..<equals].trimmingWhitespace().lowercased()
        guard !key.isEmpty else { return nil }
        let rawValue = field.raw[field.raw.index(after: equals)...].trimmingWhitespace()
        if rawValue.hasPrefix("\""), rawValue.hasSuffix("\""), rawValue.unicodeScalars.count >= 2 {
            return (key, unquote(rawValue))
        }
        return (key, rawValue)
    }
}

extension StringProtocol {
    /// 去掉首尾空格与制表符（不依赖 Foundation 的字符集）。
    func trimmingWhitespace() -> String {
        let string = String(self)
        let scalars = string.unicodeScalars
        guard let first = scalars.firstIndex(where: { $0 != " " && $0 != "\t" }),
            let last = scalars.lastIndex(where: { $0 != " " && $0 != "\t" })
        else { return "" }
        return String(Substring(scalars[first...last]))
    }
}
