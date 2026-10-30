import AetherFoundation

/// 域名通配模式：`*` 匹配任意长度（含点）的字符，`?` 匹配一个字符；不区分大小写。
/// 用于 `[Host]`、`always-real-ip` 等（docs/04 §8、07 §3.3）。
public struct DomainPattern: Hashable, Sendable, CustomStringConvertible {
    public let pattern: String
    private let bytes: [UInt8]
    public let isWildcard: Bool

    public init(_ pattern: String) {
        let lowered = pattern.lowercased()
        self.pattern = lowered
        bytes = Array(lowered.utf8)
        isWildcard = lowered.contains("*") || lowered.contains("?")
    }

    public var description: String { pattern }

    /// `domain` 须为规范化（小写）域名。
    public func matches(_ domain: String) -> Bool {
        if !isWildcard {
            return pattern == domain
        }
        return Self.glob(bytes[...], Array(domain.utf8)[...])
    }

    /// 迭代式通配匹配（回溯到最近的 `*`），O(n·m) 最坏情况，无递归。
    private static func glob(_ pattern: ArraySlice<UInt8>, _ text: ArraySlice<UInt8>) -> Bool {
        var p = pattern.startIndex
        var t = text.startIndex
        var star: Int?
        var mark = text.startIndex
        while t < text.endIndex {
            if p < pattern.endIndex, pattern[p] == UInt8(ascii: "?") || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if p < pattern.endIndex, pattern[p] == UInt8(ascii: "*") {
                star = p
                mark = t
                p += 1
            } else if let starIndex = star {
                p = starIndex + 1
                mark += 1
                t = mark
            } else {
                return false
            }
        }
        while p < pattern.endIndex, pattern[p] == UInt8(ascii: "*") {
            p += 1
        }
        return p == pattern.endIndex
    }
}

/// `[Host]` 的一个条目（由引擎从配置的 `HostSpec` 转换而来，`AetherDNS` 不依赖 `AetherProfile`）。
public struct HostEntry: Hashable, Sendable {
    public enum Value: Hashable, Sendable {
        /// 静态地址。
        case addresses([IPAddress])
        /// 别名：改为解析目标域名。
        case alias(String)
        /// 指定上游（`server:` 后的原文，如 `system`、`192.0.2.53`）。
        case upstream(String)
    }

    public var pattern: DomainPattern
    public var value: Value

    public init(pattern: String, value: Value) {
        self.pattern = DomainPattern(pattern)
        self.value = value
    }
}

/// `[Host]` 映射表（docs/07 §1）：精确条目哈希查找，通配条目按配置顺序依次匹配；精确条目优先。
public struct HostTable: Sendable {
    private var exact: [String: HostEntry.Value] = [:]
    private var wildcards: [HostEntry] = []

    public init(entries: [HostEntry] = []) {
        for entry in entries {
            if entry.pattern.isWildcard {
                wildcards.append(entry)
            } else if exact[entry.pattern.pattern] == nil {
                exact[entry.pattern.pattern] = entry.value
            }
        }
    }

    public var isEmpty: Bool { exact.isEmpty && wildcards.isEmpty }

    /// 查找规范化域名对应的条目值。
    public func lookup(_ domain: String) -> HostEntry.Value? {
        if let value = exact[domain] {
            return value
        }
        return wildcards.first { $0.pattern.matches(domain) }?.value
    }
}

/// 真实 IP 例外（docs/07 §3.3）：这些域名在 Fake IP 模式下仍返回真实解析结果。
public struct RealIPExceptions: Sendable {
    /// 内置表。
    public static let builtin = [
        "*.lan", "*.local", "*.localdomain", "*.home.arpa", "localhost", "captive.apple.com", "time.apple.com",
        "time-ios.apple.com", "*.ntp.org", "stun.*",
    ]

    private let table: HostTable

    /// - Parameter patterns: 配置中的 `always-real-ip`；为 nil 时使用内置表。
    public init(patterns: [String]?) {
        table = HostTable(
            entries: (patterns ?? Self.builtin).map { HostEntry(pattern: $0, value: .addresses([])) })
    }

    public func contains(_ domain: String) -> Bool {
        table.lookup(domain) != nil
    }
}
