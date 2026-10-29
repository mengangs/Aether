import AetherFoundation
import Foundation

/// 运行环境标识符（docs/03 §3.2）。代码只通过本类型读取 Bundle ID、App Group、Keychain 组与 URL Scheme，
/// 不得硬编码；缺少 Info.plist 键时抛 `IPC-020`，不得回退到默认值。
public struct AppEnvironment: Sendable, Equatable {
    /// Info.plist 中的键。
    public enum InfoKey: String, CaseIterable, Sendable {
        case bundleIdentifierPrefix = "AetherBundleIdentifierPrefix"
        case appGroupIdentifier = "AetherAppGroupIdentifier"
        case keychainAccessGroup = "AetherKeychainAccessGroup"
        case tunnelBundleIdentifier = "AetherTunnelBundleIdentifier"
        case urlScheme = "AetherURLScheme"
    }

    /// 主 App 的 Bundle ID，兼作日志 subsystem、Darwin 通知名等的前缀。
    public let bundleIdentifierPrefix: String
    public let appGroupIdentifier: String
    /// Keychain 访问组。启动时经 `resolvingKeychainAccessGroup(probed:)` 校正 Team ID 前缀。
    public let keychainAccessGroup: String
    public let tunnelBundleIdentifier: String
    public let urlScheme: String

    public init(
        bundleIdentifierPrefix: String,
        appGroupIdentifier: String,
        keychainAccessGroup: String,
        tunnelBundleIdentifier: String,
        urlScheme: String
    ) {
        self.bundleIdentifierPrefix = bundleIdentifierPrefix
        self.appGroupIdentifier = appGroupIdentifier
        self.keychainAccessGroup = keychainAccessGroup
        self.tunnelBundleIdentifier = tunnelBundleIdentifier
        self.urlScheme = urlScheme
    }

    /// 从 Info.plist 字典读取。
    /// - Throws: `AppEnvironmentError`（`IPC-020`）：缺少键、类型不对、值为空、含未展开的 `$(...)` 或非法字符。
    public init(infoDictionary: [String: Any]) throws {
        func value(_ key: InfoKey) throws -> String {
            guard let raw = infoDictionary[key.rawValue] else {
                throw AppEnvironmentError.missingKey(key.rawValue)
            }
            guard let string = raw as? String else {
                throw AppEnvironmentError.invalidValue(key: key.rawValue, value: String(describing: raw))
            }
            guard Self.isValid(string, for: key) else {
                throw AppEnvironmentError.invalidValue(key: key.rawValue, value: string)
            }
            return string
        }
        self.init(
            bundleIdentifierPrefix: try value(.bundleIdentifierPrefix),
            appGroupIdentifier: try value(.appGroupIdentifier),
            keychainAccessGroup: try value(.keychainAccessGroup),
            tunnelBundleIdentifier: try value(.tunnelBundleIdentifier),
            urlScheme: try value(.urlScheme)
        )
    }

    /// 从主 Bundle 的 Info.plist 读取。失败时调用方负责记录日志并向用户展示错误。
    public static func fromMainBundle() throws -> AppEnvironment {
        try AppEnvironment(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func isValid(_ value: String, for key: InfoKey) -> Bool {
        guard !value.isEmpty, !value.contains("$(") else { return false }
        let allowed: (Character) -> Bool = { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
        switch key {
        case .urlScheme:
            // RFC 3986：字母开头，后续为字母、数字、+、-、.
            guard let first = value.first, first.isASCII, first.isLetter else { return false }
            return value.allSatisfy { allowed($0) || $0 == "+" }
        case .keychainAccessGroup:
            // 未签名构建且未设置 Team ID 时以 "." 开头（前缀为空），运行时探测校正。
            return value.allSatisfy(allowed) && value.contains(where: { $0 != "." })
        default:
            return value.allSatisfy(allowed) && !value.hasPrefix(".") && !value.hasSuffix(".")
        }
    }

    // MARK: - Keychain 访问组校正（docs/03 §8.4）

    /// Keychain 访问组 Team ID 前缀的校正结果。
    public enum KeychainAccessGroupResolution: Equatable, Sendable {
        /// Info.plist 中的前缀与探测结果一致。
        case matched
        /// 不一致，已改用探测到的前缀。
        case corrected(from: String, to: String)
        /// 探测失败（如 Keychain 不可用），保留 Info.plist 中的值。
        case probeFailed
    }

    /// 用探测到的访问组校正 Team ID 前缀（第一个 `.` 之前的部分），其余部分保持不变。
    /// - Parameter probed: 不指定访问组写入临时 Keychain 项后系统赋予的 `kSecAttrAccessGroup`。
    public func resolvingKeychainAccessGroup(probed: String?) -> (AppEnvironment, KeychainAccessGroupResolution) {
        guard let probed, let probedPrefix = Self.teamPrefix(of: probed), !probedPrefix.isEmpty else {
            return (self, .probeFailed)
        }
        let configuredPrefix = Self.teamPrefix(of: keychainAccessGroup) ?? ""
        guard configuredPrefix != probedPrefix else {
            return (self, .matched)
        }
        let suffix: Substring
        if let dot = keychainAccessGroup.firstIndex(of: ".") {
            suffix = keychainAccessGroup[keychainAccessGroup.index(after: dot)...]
        } else {
            suffix = Substring(keychainAccessGroup)
        }
        let corrected = "\(probedPrefix).\(suffix)"
        let resolved = AppEnvironment(
            bundleIdentifierPrefix: bundleIdentifierPrefix,
            appGroupIdentifier: appGroupIdentifier,
            keychainAccessGroup: corrected,
            tunnelBundleIdentifier: tunnelBundleIdentifier,
            urlScheme: urlScheme
        )
        return (resolved, .corrected(from: keychainAccessGroup, to: corrected))
    }

    /// 访问组的 Team ID 前缀：第一个 `.` 之前的部分；没有 `.` 时为 nil。
    public static func teamPrefix(of accessGroup: String) -> String? {
        guard let dot = accessGroup.firstIndex(of: ".") else { return nil }
        return String(accessGroup[..<dot])
    }

    // MARK: - 派生名称

    /// 状态快照变化通知（docs/10 §3）。
    public var statusNotificationName: String { "\(bundleIdentifierPrefix).notify.status" }
    /// 日志簿新增事件通知（docs/10 §3）。
    public var logbookNotificationName: String { "\(bundleIdentifierPrefix).notify.logbook" }
}

/// `AppEnvironment` 读取失败（`IPC-020`）。
public enum AppEnvironmentError: AetherErrorProtocol, Equatable {
    case missingKey(String)
    case invalidValue(key: String, value: String)

    public var code: AetherErrorCode { .ipcInvalidEnvironment }

    public var debugDetails: String {
        switch self {
        case .missingKey(let key):
            return "Info.plist is missing \(key)"
        case .invalidValue(let key, let value):
            return "Info.plist has an invalid value for \(key): \(value)"
        }
    }
}
