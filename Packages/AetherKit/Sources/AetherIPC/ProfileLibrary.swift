import AetherFoundation
import Foundation

/// 配置索引条目（docs/11 §3.1）。
public struct ProfileEntry: Codable, Sendable, Identifiable, Equatable {
    public enum Source: Codable, Sendable, Equatable {
        case local
        case managed(url: String, interval: TimeInterval, strict: Bool)
        case imported(url: String)
    }

    public let id: UUID
    /// 显示名，可重命名，与文件名无关。
    public var name: String
    public var source: Source
    public var createdAt: Date
    public var updatedAt: Date
    /// 托管配置。
    public var lastUpdateAttemptAt: Date?
    public var lastUpdateError: String?
    /// 文件内容 SHA-256（由调用方计算）。
    public var revision: String

    public init(
        id: UUID = UUID(), name: String, source: Source, createdAt: Date, updatedAt: Date, revision: String,
        lastUpdateAttemptAt: Date? = nil, lastUpdateError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision
        self.lastUpdateAttemptAt = lastUpdateAttemptAt
        self.lastUpdateError = lastUpdateError
    }
}

/// 模块索引条目（docs/11 §3.1）。数组顺序即叠加顺序。
public struct ModuleEntry: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    /// 取自 `#!name`。
    public var name: String
    public var enabled: Bool
    public var sourceURL: String?
    /// 用户填写的参数值。
    public var arguments: [String: String]
    public var updatedAt: Date
    public var lastError: String?

    public init(
        id: UUID = UUID(), name: String, enabled: Bool, sourceURL: String? = nil, arguments: [String: String] = [:],
        updatedAt: Date, lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.sourceURL = sourceURL
        self.arguments = arguments
        self.updatedAt = updatedAt
        self.lastError = lastError
    }
}

/// `Profiles/` 与 `Modules/` 的读写（App 侧，docs/11 §2–§3）：索引原子替换，内容文件以 UUID 命名。
public struct ProfileLibrary: Sendable {
    /// 配置数上限；超出时拒绝导入（`IPC-011`）。
    public static let maxProfiles = 128
    /// 单个配置或模块文本的大小上限（docs/11 §5.1 托管配置）。
    public static let maxTextBytes = 4 * 1024 * 1024

    public let container: SharedContainer

    public init(container: SharedContainer) {
        self.container = container
    }

    var profileIndex: URL { container.profiles.appendingPathComponent("index.json") }
    var moduleIndex: URL { container.modules.appendingPathComponent("index.json") }

    func profileFile(_ id: UUID) -> URL { container.profiles.appendingPathComponent("\(id.uuidString).conf") }
    func moduleFile(_ id: UUID) -> URL { container.modules.appendingPathComponent("\(id.uuidString).amodule") }

    /// 全部配置，按索引顺序。
    public func profiles() -> [ProfileEntry] {
        JSONStateFile.read([ProfileEntry].self, from: profileIndex) ?? []
    }

    /// 全部模块，按叠加顺序。
    public func modules() -> [ModuleEntry] {
        JSONStateFile.read([ModuleEntry].self, from: moduleIndex) ?? []
    }

    /// 配置文本。
    /// - Throws: `IPC-011`：条目不存在或文件无法读取。
    public func text(of profile: ProfileEntry) throws -> String {
        try readText(profileFile(profile.id))
    }

    public func text(of module: ModuleEntry) throws -> String {
        try readText(moduleFile(module.id))
    }

    /// 写入一个新配置并加入索引。
    /// - Throws: `IPC-011`：文本超过 4 MiB 或配置数达到上限。
    @discardableResult
    public func addProfile(name: String, text: String, source: ProfileEntry.Source, revision: String, now: Date)
        throws -> ProfileEntry
    {
        var entries = profiles()
        guard entries.count < Self.maxProfiles else {
            throw IPCError(code: .ipcInvalidArgument, message: "At most \(Self.maxProfiles) profiles")
        }
        let entry = ProfileEntry(name: name, source: source, createdAt: now, updatedAt: now, revision: revision)
        try write(text, to: profileFile(entry.id))
        entries.append(entry)
        try JSONStateFile.write(entries, to: profileIndex)
        return entry
    }

    /// 替换配置文本（编辑、托管更新）。
    public func updateProfile(_ id: UUID, text: String, revision: String, now: Date) throws {
        var entries = profiles()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw IPCError(code: .ipcInvalidArgument, message: "No profile \(id)")
        }
        try write(text, to: profileFile(id))
        entries[index].revision = revision
        entries[index].updatedAt = now
        try JSONStateFile.write(entries, to: profileIndex)
    }

    public func renameProfile(_ id: UUID, to name: String) throws {
        var entries = profiles()
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            throw IPCError(code: .ipcInvalidArgument, message: "No profile \(id)")
        }
        entries[index].name = name
        try JSONStateFile.write(entries, to: profileIndex)
    }

    /// 删除配置；当前运行包引用的配置不可删除（`IPC-012`）。
    public func removeProfile(_ id: UUID) throws {
        if let manifest = RunBundle.activeManifest(in: container), manifest.profileID == id.uuidString {
            throw IPCError(code: .ipcInvalidState, message: "The current profile cannot be deleted")
        }
        var entries = profiles()
        entries.removeAll { $0.id == id }
        try JSONStateFile.write(entries, to: profileIndex)
        try? FileManager.default.removeItem(at: profileFile(id))
    }

    private func write(_ text: String, to url: URL) throws {
        let data = Data(text.utf8)
        guard data.count <= Self.maxTextBytes else {
            throw IPCError(code: .ipcInvalidArgument, message: "Text is larger than 4 MiB")
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func readText(_ url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw IPCError(code: .ipcInvalidArgument, message: "Cannot read \(url.lastPathComponent)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension RunBundle {
    /// 保留的运行包目录数（docs/11 §6 第 5 步）。
    public static let retainedBundles = 3

    /// 当前运行包的清单；没有时为 nil。
    public static func activeManifest(in container: SharedContainer) -> BundleManifest? {
        guard let pointer = JSONStateFile.read(ActiveBundlePointer.self, from: container.activeBundlePointer),
            let directory = try? resolve(pointer.bundle, under: container.root)
        else { return nil }
        return JSONStateFile.read(BundleManifest.self, from: directory.appendingPathComponent("manifest.json"))
    }

    /// 提交运行包（App 侧，docs/11 §6 第 2、3、5 步）：在 `Bundles/<修订号前 16 位>` 写入配置、模块（参数值已代入的文本）
    /// 与清单，原子替换 `active.json`，保留最近 3 个运行包目录。`revision` 由调用方用 `AetherProfile` 计算。
    @discardableResult
    public static func commit(
        profile: ProfileEntry, profileText: String, modules: [(entry: ModuleEntry, text: String)], revision: String,
        appVersion: String, now: Date, container: SharedContainer
    ) throws -> ActiveBundlePointer {
        let hex = revision.split(separator: ":").last.map(String.init) ?? revision
        let name = String(hex.filter { $0.isLetter || $0.isNumber }.prefix(16))
        guard !name.isEmpty else {
            throw IPCError(code: .ipcInvalidArgument, message: "Invalid revision \(revision)")
        }
        let directory = container.bundles.appendingPathComponent(name)
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory.appendingPathComponent("modules"), withIntermediateDirectories: true)
        try Data(profileText.utf8).write(to: directory.appendingPathComponent("profile.conf"), options: .atomic)
        var entries: [BundleManifest.Module] = []
        for (index, module) in modules.enumerated() {
            let file = "modules/\(String(format: "%02d", index + 1))-\(module.entry.id.uuidString).amodule"
            try Data(module.text.utf8).write(to: directory.appendingPathComponent(file), options: .atomic)
            entries.append(.init(id: module.entry.id.uuidString, name: module.entry.name, file: file))
        }
        let manifest = BundleManifest(
            revision: revision, profileID: profile.id.uuidString, profileName: profile.name, committedAt: now,
            appVersion: appVersion, modules: entries)
        try JSONStateFile.write(manifest, to: directory.appendingPathComponent("manifest.json"))
        let pointer = ActiveBundlePointer(revision: revision, bundle: "Bundles/\(name)", committedAt: now)
        try JSONStateFile.write(pointer, to: container.activeBundlePointer)
        removeOldBundles(keeping: name, container: container)
        return pointer
    }

    /// 删除更早的运行包目录：保留最近修改的 `retainedBundles` 个，以及当前引用的目录。
    static func removeOldBundles(keeping current: String, container: SharedContainer) {
        let fileManager = FileManager.default
        guard
            let names = try? fileManager.contentsOfDirectory(
                at: container.bundles, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        let dated = names.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (url, date ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (index, entry) in dated.enumerated() where index >= retainedBundles && entry.0.lastPathComponent != current
        {
            try? fileManager.removeItem(at: entry.0)
        }
    }
}
