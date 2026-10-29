import AetherIPC
import Foundation
import Logging
import Security

/// 探测本进程实际可用的 Keychain 访问组前缀（docs/03 §8.4）。
///
/// 写入一个不指定 `kSecAttrAccessGroup` 的临时通用密码项，读回系统赋予的访问组（即 entitlements 中第一个访问组），
/// 然后立即删除该项。重签后描述文件的 Team ID 可能与构建时不同，以探测结果为准。
public enum KeychainAccessGroupProbe {
    /// 返回系统赋予临时项的访问组；Keychain 不可用或没有访问组 entitlement 时返回 nil。
    public static func probeDefaultAccessGroup(service: String) -> String? {
        let account = "probe-\(UUID().uuidString)"
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var add = base
        add[kSecValueData as String] = Data()
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemAdd(add as CFDictionary, &result)
        defer { SecItemDelete(base as CFDictionary) }
        guard status == errSecSuccess, let attributes = result as? [String: Any] else {
            return nil
        }
        return attributes[kSecAttrAccessGroup as String] as? String
    }
}

extension AppEnvironment {
    /// 读取主 Bundle 的标识符并校正 Keychain 访问组前缀；校正或探测失败时写日志。
    /// - Throws: `AppEnvironmentError`（`IPC-020`）。
    public static func loadForCurrentProcess(logger: Logger) throws -> AppEnvironment {
        do {
            return try AppEnvironment.fromMainBundle().resolvingKeychainAccessGroupForCurrentProcess(logger: logger)
        } catch let error as AppEnvironmentError {
            logger.error(
                "AppEnvironment unavailable", metadata: ["code": "\(error.code)", "details": "\(error.debugDetails)"])
            throw error
        }
    }

    /// 在本进程中探测 Keychain 访问组并校正前缀，结果写日志（docs/03 §8.4）。
    public func resolvingKeychainAccessGroupForCurrentProcess(logger: Logger) -> AppEnvironment {
        let probed = KeychainAccessGroupProbe.probeDefaultAccessGroup(
            service: "\(bundleIdentifierPrefix).keychain-probe")
        let (resolved, resolution) = resolvingKeychainAccessGroup(probed: probed)
        switch resolution {
        case .matched:
            logger.info("Keychain access group verified", metadata: ["group": "\(resolved.keychainAccessGroup)"])
        case .corrected(let from, let to):
            logger.warning(
                "Keychain access group prefix differs from Info.plist; using the probed prefix",
                metadata: ["configured": "\(from)", "resolved": "\(to)"]
            )
        case .probeFailed:
            logger.warning(
                "Keychain access group probe failed; keeping the Info.plist value",
                metadata: ["configured": "\(keychainAccessGroup)"]
            )
        }
        return resolved
    }
}
