import AetherFoundation
import Foundation

/// App Group 容器中的 `Aether/` 目录布局（docs/11 §3）。
public struct SharedContainer: Sendable, Equatable {
    /// `<App Group>/Aether`。
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 定位 App Group 容器。
    /// - Parameters:
    ///   - appGroupIdentifier: 来自 `AppEnvironment`。
    ///   - containerURL: 平台查找函数，Apple 平台传入
    ///     `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`。
    /// - Throws: `SharedContainerError.appGroupUnavailable`（`STO-001`）。调用方必须向用户展示明确的错误，不得崩溃。
    public static func locate(appGroupIdentifier: String, containerURL: (String) -> URL?) throws -> SharedContainer {
        guard let base = containerURL(appGroupIdentifier) else {
            throw SharedContainerError.appGroupUnavailable(appGroupIdentifier)
        }
        return SharedContainer(root: base.appendingPathComponent("Aether", isDirectory: true))
    }

    public var profiles: URL { directory("Profiles") }
    public var modules: URL { directory("Modules") }
    public var scripts: URL { directory("Scripts") }
    public var resources: URL { directory("Resources") }
    public var bundles: URL { directory("Bundles") }
    public var activeBundlePointer: URL { root.appendingPathComponent("active.json") }
    public var state: URL { directory("State") }
    public var database: URL { directory("Database") }
    public var logs: URL { directory("Logs") }
    public var capture: URL { directory("Capture") }
    public var inbox: URL { directory("Inbox") }

    /// 状态快照（docs/10 §3）。
    public var tunnelStatusFile: URL { state.appendingPathComponent("tunnel-status.json") }

    private func directory(_ name: String) -> URL {
        root.appendingPathComponent(name, isDirectory: true)
    }
}

/// App Group 容器不可用（`STO-001`）：entitlements 中缺少 App Group，或签名时使用的 App Group 与 Info.plist 不一致。
public enum SharedContainerError: AetherErrorProtocol, Equatable {
    case appGroupUnavailable(String)

    public var code: AetherErrorCode { .stoAppGroupUnavailable }

    public var debugDetails: String {
        switch self {
        case .appGroupUnavailable(let identifier):
            return "App Group container \(identifier) is unavailable"
        }
    }
}
