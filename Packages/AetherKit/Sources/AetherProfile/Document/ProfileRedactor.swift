import AetherFoundation

/// 脱敏渲染（docs/04 §15.2）：把敏感值替换为 `******`，其余字符（含空白与注释）保持原样。
///
/// 覆盖：`password` 与位置字段中的密码、UUID 类协议的 `username`、`uuid`、`token`、`psk`、`ca-p12`、
/// `ca-passphrase`、`http-api` 中的密钥、`policy-path` 与 `#!MANAGED-CONFIG` URL 的查询串。
public enum ProfileRedactor {
    public static let mask = "******"

    static let secretKeys: Set<String> = ["password", "uuid", "token", "psk", "private-key", "preshared-key"]
    static let uuidProtocols: Set<String> = ["vmess", "vless", "tuic", "tuic-v5"]
    /// 位置字段第 4 个为密码的类型。
    static let positionalPasswordTypes: Set<String> = ["http", "https", "socks5", "socks5-tls"]

    static func redact(_ line: ProfileLine) -> String {
        switch line.kind {
        case .directive(let name, let value) where name.uppercased() == "MANAGED-CONFIG":
            let redacted = value.split(separator: " ", omittingEmptySubsequences: false).enumerated().map {
                index, part in
                index == 0 ? redactQuery(String(part)) : String(part)
            }.joined(separator: " ")
            return line.raw.replacingOccurrences(of: value, with: redacted)
        case .entry(let entry):
            switch line.section {
            case .proxy: return redactFields(line, entry: entry, mode: .proxy)
            case .proxyGroup: return redactFields(line, entry: entry, mode: .group)
            case .general:
                if entry.key?.lowercased() == "http-api", let at = entry.value.firstIndex(of: "@") {
                    return replaceValue(line, entry: entry, with: mask + String(entry.value[at...]))
                }
                return line.raw
            case .mitm:
                if let key = entry.key?.lowercased(), key == "ca-p12" || key == "ca-passphrase" {
                    return replaceValue(line, entry: entry, with: mask)
                }
                return line.raw
            default:
                return line.raw
            }
        default:
            return line.raw
        }
    }

    enum Mode {
        case proxy
        case group
    }

    /// 按字段偏移替换值中的敏感部分。
    static func redactFields(_ line: ProfileLine, entry: ProfileEntry, mode: Mode) -> String {
        guard case .success(let fields) = FieldTokenizer.split(entry.value) else {
            // 无法分词（如引号未闭合）时整体遮盖值，宁可多遮。
            return replaceValue(line, entry: entry, with: mask)
        }
        let type = fields.first?.value.lowercased() ?? ""
        var valueScalars = Array(entry.value.unicodeScalars)
        var replacements: [(range: Range<Int>, text: String)] = []
        var positionalIndex = 0
        for (index, field) in fields.enumerated() where index > 0 {
            let start = field.offset
            let end = start + field.raw.unicodeScalars.count
            if let (key, value) = FieldTokenizer.keyValue(field) {
                let isSecret: Bool
                switch mode {
                case .proxy:
                    isSecret = secretKeys.contains(key) || (key == "username" && uuidProtocols.contains(type))
                case .group:
                    isSecret = false
                }
                if isSecret {
                    replacements.append((start..<end, "\(rawKey(of: field))=\(mask)"))
                } else if key == "policy-path" {
                    replacements.append((start..<end, "\(rawKey(of: field))=\(redactQuery(value))"))
                }
            } else {
                positionalIndex += 1
                if mode == .proxy, positionalPasswordTypes.contains(type), positionalIndex == 4, !field.value.isEmpty {
                    replacements.append((start..<end, mask))
                }
            }
        }
        guard !replacements.isEmpty else { return line.raw }
        for replacement in replacements.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let upper = min(replacement.range.upperBound, valueScalars.count)
            let lower = min(replacement.range.lowerBound, upper)
            valueScalars.replaceSubrange(lower..<upper, with: Array(replacement.text.unicodeScalars))
        }
        return replaceValue(line, entry: entry, with: String(String.UnicodeScalarView(valueScalars)))
    }

    /// `key=value` 字段中键的原样书写。
    static func rawKey(of field: FieldTokenizer.Field) -> String {
        guard let equals = field.raw.firstIndex(of: "=") else { return field.raw }
        return String(field.raw[..<equals])
    }

    /// 只替换行中值的部分，保留其前的缩进、键与 `=`，以及值后的空白。
    static func replaceValue(_ line: ProfileLine, entry: ProfileEntry, with newValue: String) -> String {
        let scalars = Array(line.raw.unicodeScalars)
        let start = max(0, min(entry.valueColumn - 1, scalars.count))
        let end = min(start + entry.value.unicodeScalars.count, scalars.count)
        let prefix = String(String.UnicodeScalarView(scalars[..<start]))
        let suffix = String(String.UnicodeScalarView(scalars[end...]))
        return prefix + newValue + suffix
    }

    /// 遮盖 URL 的查询串：`https://a/b?token=x` → `https://a/b?******`。
    static func redactQuery(_ url: String) -> String {
        guard let question = url.firstIndex(of: "?") else { return url }
        var result = String(url[...question]) + mask
        if let hash = url[question...].firstIndex(of: "#") {
            result += url[hash...]
        }
        return result
    }
}

extension ProfileDocument {
    /// 渲染；`redactingSecrets` 为 true 时遮盖敏感值（导出、分享、截图预览默认脱敏，docs/02 §9）。
    public func render(redactingSecrets: Bool) -> String {
        guard redactingSecrets else { return render() }
        var output = hasBOM ? "\u{FEFF}" : ""
        for line in lines {
            output += ProfileRedactor.redact(line)
            output += line.terminator
        }
        return output
    }
}
