import AetherFoundation
import Foundation

/// `active.json`（docs/11 §6）：指向当前运行包。App 原子替换，隧道只读。
public struct ActiveBundlePointer: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var revision: String
    /// 相对于 `Aether/` 的运行包目录（`Bundles/<修订号前 16 位>`）。
    public var bundle: String
    public var committedAt: Date

    public init(revision: String, bundle: String, committedAt: Date) {
        schemaVersion = Self.currentSchemaVersion
        self.revision = revision
        self.bundle = bundle
        self.committedAt = committedAt
    }
}

/// 运行包的 `manifest.json`（docs/11 §6）。
public struct BundleManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public struct Module: Codable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// 相对于运行包目录的文件（`modules/<序号>-<uuid>.amodule`），参数值已代入。
        public var file: String

        public init(id: String, name: String, file: String) {
            self.id = id
            self.name = name
            self.file = file
        }
    }

    public var schemaVersion: Int
    public var revision: String
    public var profileID: String
    public var profileName: String
    public var committedAt: Date
    public var appVersion: String
    public var modules: [Module]

    public init(
        revision: String, profileID: String, profileName: String, committedAt: Date, appVersion: String,
        modules: [Module]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.revision = revision
        self.profileID = profileID
        self.profileName = profileName
        self.committedAt = committedAt
        self.appVersion = appVersion
        self.modules = modules
    }
}

/// 读入内存的运行包：清单、配置文本与模块文本（按清单顺序，即叠加顺序）。
public struct LoadedBundle: Sendable, Equatable {
    public struct Module: Sendable, Equatable {
        public var name: String
        public var text: String
    }

    public var manifest: BundleManifest
    public var directory: URL
    public var profileText: String
    public var modules: [Module]
}

/// 运行包的读取（隧道侧，docs/06 §2.2 第 2 步、docs/11 §6）。
public enum RunBundle {
    /// 运行包中配置与单个模块的大小上限（与托管配置相同，docs/11 §5.1）。
    public static let maxFileBytes = 4 * 1024 * 1024
    /// 运行包中的模块数上限。
    public static let maxModules = 64

    /// 读取 `active.json` 指向的运行包。
    /// - Throws: `IPC-010`：`active.json` 不存在或无法解析、清单或配置缺失、文件超过上限、路径越出容器。
    public static func loadActive(from container: SharedContainer) throws -> LoadedBundle {
        guard let pointer = JSONStateFile.read(ActiveBundlePointer.self, from: container.activeBundlePointer) else {
            throw IPCError(code: .ipcNoActiveBundle, message: "No active bundle (active.json missing or unreadable)")
        }
        let directory = try resolve(pointer.bundle, under: container.root)
        guard
            let manifest = JSONStateFile.read(
                BundleManifest.self, from: directory.appendingPathComponent("manifest.json"))
        else {
            throw IPCError(code: .ipcNoActiveBundle, message: "Bundle manifest missing or unreadable")
        }
        guard manifest.modules.count <= maxModules else {
            throw IPCError(code: .ipcNoActiveBundle, message: "Bundle has more than \(maxModules) modules")
        }
        let profileText = try readText(directory.appendingPathComponent("profile.conf"))
        let modules = try manifest.modules.map { module in
            LoadedBundle.Module(
                name: module.name, text: try readText(try resolve(module.file, under: directory)))
        }
        return LoadedBundle(manifest: manifest, directory: directory, profileText: profileText, modules: modules)
    }

    /// 相对路径解析到 `base` 之下；含 `..` 或绝对路径时拒绝。
    static func resolve(_ relative: String, under base: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !relative.hasPrefix("/"), !components.isEmpty, !components.contains("..") else {
            throw IPCError(code: .ipcNoActiveBundle, message: "Invalid bundle path \(relative)")
        }
        return components.reduce(base) { $0.appendingPathComponent(String($1)) }
    }

    private static func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw IPCError(code: .ipcNoActiveBundle, message: "Bundle file missing: \(url.lastPathComponent)")
        }
        guard data.count <= maxFileBytes else {
            throw IPCError(code: .ipcNoActiveBundle, message: "Bundle file too large: \(url.lastPathComponent)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
