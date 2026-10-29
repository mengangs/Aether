/// 规范化的主机名（docs/05 §3.3）：ASCII 小写、去掉末尾的 `.`，含非 ASCII 字符的标签转为 Punycode（`xn--`）。
/// 比较一律用 A-label；原始拼写只用于展示。
///
/// IDNA 映射只做 Unicode 小写化，不实现完整的 UTS #46（兼容性映射、上下文规则等）；对常见的中文、日文、带重音字母域名足够。
public struct Hostname: Hashable, Sendable, Comparable, CustomStringConvertible {
    /// 规范化后的 ASCII 形式（A-label）。
    public let value: String
    /// 原始拼写（展示用，不参与比较）。
    public let original: String

    /// 主机名最大长度（RFC 1035，按 A-label 计）。
    public static let maxLength = 253

    /// 规范化。空串、含空白或控制字符、标签为空（`a..b`）、超长时返回 nil。
    public init?(_ text: some StringProtocol) {
        let original = String(text)
        var trimmed = Substring(original)
        if trimmed.hasSuffix(".") {
            trimmed = trimmed.dropLast()
        }
        guard !trimmed.isEmpty else { return nil }
        var labels: [String] = []
        for label in trimmed.split(separator: ".", omittingEmptySubsequences: false) {
            guard !label.isEmpty, label.utf8.count <= 255 else { return nil }
            if label.unicodeScalars.allSatisfy(\.isASCII) {
                guard
                    label.unicodeScalars.allSatisfy({
                        !$0.properties.isWhitespace && $0.value > 0x20 && $0.value != 0x7F
                    })
                else { return nil }
                labels.append(label.lowercased())
            } else {
                guard label.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.value > 0x20 }) else {
                    return nil
                }
                guard let encoded = Punycode.encode(label.lowercased()) else { return nil }
                labels.append("xn--" + encoded)
            }
        }
        let value = labels.joined(separator: ".")
        guard value.utf8.count <= Self.maxLength else { return nil }
        self.value = value
        self.original = original
    }

    /// 已经是规范 ASCII 形式的值（内部构造用，不校验）。
    init(normalized value: String) {
        self.value = value
        self.original = value
    }

    public var description: String { value }

    /// Unicode 展示形式：`xn--` 标签解码；解码失败的标签保持原样。
    public var unicodeDisplay: String {
        value.split(separator: ".").map { label -> String in
            if label.hasPrefix("xn--"), let decoded = Punycode.decode(label.dropFirst(4)) {
                return decoded
            }
            return String(label)
        }.joined(separator: ".")
    }

    /// 是否为 IP 字面量。
    public var isIPAddress: Bool { IPAddress(value) != nil }

    /// 不含点的主机名（HOSTNAME-TYPE SIMPLE）。
    public var isSimple: Bool { !value.contains(".") }

    /// 等于 `suffix` 或以 `.suffix` 结尾（DOMAIN-SUFFIX 语义）。
    public func hasDomainSuffix(_ suffix: Hostname) -> Bool {
        value == suffix.value || value.hasSuffix("." + suffix.value)
    }

    public static func == (lhs: Hostname, rhs: Hostname) -> Bool { lhs.value == rhs.value }
    public func hash(into hasher: inout Hasher) { hasher.combine(value) }
    public static func < (lhs: Hostname, rhs: Hostname) -> Bool { lhs.value < rhs.value }
}

/// 主机 + 端口。主机可以是域名或 IP 字面量。
public struct Endpoint: Hashable, Sendable, CustomStringConvertible {
    public enum Host: Hashable, Sendable {
        case name(Hostname)
        case address(IPAddress)
    }

    public var host: Host
    public var port: UInt16

    public init(host: Host, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// 由字符串主机构造：IP 字面量优先，其次规范化域名。
    public init?(host text: some StringProtocol, port: UInt16) {
        if let address = IPAddress(text) {
            self.init(host: .address(address), port: port)
        } else if let name = Hostname(text) {
            self.init(host: .name(name), port: port)
        } else {
            return nil
        }
    }

    /// `host:port`，IPv6 加方括号。
    public var description: String {
        switch host {
        case .name(let name): return "\(name):\(port)"
        case .address(.v6(let v6)): return "[\(v6)]:\(port)"
        case .address(.v4(let v4)): return "\(v4):\(port)"
        }
    }
}
