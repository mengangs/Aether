import AetherControl
import AetherIPC
import AetherProfile
import CryptoKit
import Foundation
import Observation

/// App 中的 `ProfileEntry` 指配置索引条目（docs/11 §3.1）；`AetherProfile` 中同名的类型是配置文档的条目。
typealias ProfileEntry = AetherIPC.ProfileEntry

/// 配置库（docs/11 §3、§6，docs/12 §7.1）：配置列表、导入确认、提交运行包并在隧道运行时请求重载。
@MainActor
@Observable
final class ProfileStore {
    /// 导入确认页的内容：来源、预览、诊断摘要与将下载的外部资源。
    struct ImportReview: Identifiable {
        let id = UUID()
        var name: String
        var text: String
        var source: ProfileEntry.Source
        var diagnostics: [Diagnostic]
        var resources: [String]

        var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
        var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }
        var canImport: Bool { errorCount == 0 }
    }

    /// 从 URL 下载配置的大小上限（docs/11 §5.1 托管配置）。
    static let maxDownloadBytes = ProfileLibrary.maxTextBytes

    let library: ProfileLibrary
    /// 导入与切换后下载配置引用的外部资源（docs/11 §5.4）；为 nil 时不下载（预览）。
    @ObservationIgnored let resources: ResourceRefresher?
    private(set) var entries: [ProfileEntry] = []
    private(set) var currentProfileID: UUID?
    private(set) var lastError: String?

    init(container: SharedContainer, resources: ResourceRefresher? = nil) {
        library = ProfileLibrary(container: container)
        self.resources = resources
        reload()
    }

    func reload() {
        entries = library.profiles()
        currentProfileID = RunBundle.activeManifest(in: library.container).flatMap { UUID(uuidString: $0.profileID) }
    }

    var currentProfile: ProfileEntry? {
        entries.first { $0.id == currentProfileID }
    }

    // MARK: - 导入（docs/12 §7.1）

    func review(name: String, text: String, source: ProfileEntry.Source) -> ImportReview {
        let resolved = ProfileResolver.resolve(profileText: text, fileName: name)
        let resources = resolved.externalResources.map { Self.redactQuery($0.url) }
        return ImportReview(
            name: name, text: text, source: source, diagnostics: resolved.diagnostics, resources: resources)
    }

    /// 下载 URL 的配置并生成导入确认。
    func review(url: URL) async throws -> ImportReview {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ProfileStoreError(message: "下载失败：HTTP \(http.statusCode)")
        }
        guard data.count <= Self.maxDownloadBytes else {
            throw ProfileStoreError(message: "配置超过 4 MiB")
        }
        let name = url.deletingPathExtension().lastPathComponent.isEmpty ? "Profile" : url.deletingPathExtension().lastPathComponent
        return review(name: name, text: String(decoding: data, as: UTF8.self), source: .imported(url: url.absoluteString))
    }

    /// 读取用户选择的文件并生成导入确认。
    func review(file url: URL) throws -> ImportReview {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxDownloadBytes else {
            throw ProfileStoreError(message: "配置超过 4 MiB")
        }
        return review(
            name: url.deletingPathExtension().lastPathComponent, text: String(decoding: data, as: UTF8.self),
            source: .local)
    }

    /// 确认导入：写入 `Profiles/`；没有当前配置时同时设为当前配置。
    @discardableResult
    func confirm(_ review: ImportReview, client: (any TunnelClientProtocol)?) async -> ProfileEntry? {
        do {
            let entry = try library.addProfile(
                name: review.name, text: review.text, source: review.source, revision: Self.contentHash(review.text),
                now: Date())
            reload()
            if currentProfileID == nil {
                await activate(entry, client: client)
            } else {
                // 导入时立即下载其引用的资源；失败的资源不影响导入。
                downloadResources(ProfileResolver.resolve(profileText: review.text, fileName: review.name), client: client)
            }
            lastError = nil
            return entry
        } catch {
            lastError = IPCError(error).message
            return nil
        }
    }

    // MARK: - 切换与删除

    /// 提交运行包（docs/11 §6）；隧道运行时请求 `reloadProfile`。返回是否成功。
    @discardableResult
    func activate(_ entry: ProfileEntry, client: (any TunnelClientProtocol)?) async -> Bool {
        do {
            let text = try library.text(of: entry)
            var modules: [(entry: ModuleEntry, text: String)] = []
            for module in library.modules() where module.enabled {
                let input = ModuleInput(name: module.name, text: try library.text(of: module), argumentValues: module.arguments)
                guard let substituted = input.substitutedText() else { continue }
                modules.append((module, substituted))
            }
            let resolved = ProfileResolver.resolve(
                profileText: text, fileName: entry.name,
                modules: modules.map { ModuleInput(name: $0.entry.name, text: $0.text) })
            guard resolved.isCommittable else {
                let count = resolved.diagnostics.filter { $0.severity == .error }.count
                lastError = "配置有 \(count) 个错误，未提交"
                return false
            }
            try RunBundle.commit(
                profile: entry, profileText: text, modules: modules, revision: resolved.revision,
                appVersion: Self.appVersion, now: Date(), container: library.container)
            reload()
            lastError = nil
            if let client {
                do {
                    let result = try await client.reloadProfile(expectedRevision: resolved.revision)
                    if result.errorCount > 0 {
                        lastError = "隧道拒绝了新配置（\(result.errorCount) 个错误），仍使用旧配置"
                    }
                } catch let error as IPCError where error.code == .ipcTunnelNotRunning {
                    // 隧道未运行：下次连接时使用新的运行包。
                } catch {
                    lastError = "已提交，但通知隧道重载失败：\(IPCError(error).message)"
                }
            }
            downloadResources(resolved, client: client)
            return true
        } catch {
            lastError = IPCError(error).message
            return false
        }
    }

    func delete(_ entry: ProfileEntry) {
        do {
            try library.removeProfile(entry.id)
            reload()
            lastError = nil
        } catch {
            lastError = IPCError(error).message
        }
    }

    /// 在后台下载配置引用的全部外部资源（未到期的也下载）；隧道运行时由 `resourcesChanged` 触发重载。
    private func downloadResources(_ resolved: ResolvedProfile, client: (any TunnelClientProtocol)?) {
        guard let resources else { return }
        let requests = ResourceRefresher.requests(resolved)
        Task { await resources.update(requests, force: true, client: client) }
    }

    // MARK: - 工具

    static func contentHash(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 去掉 URL 的查询串（可能含订阅令牌，docs/08 脱敏规则）。
    static func redactQuery(_ url: String) -> String {
        guard var components = URLComponents(string: url), components.query != nil else { return url }
        components.query = nil
        return (components.string ?? url) + "?…"
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }

    /// 预览用：临时目录中的配置库，可选地放入示例配置并设为当前配置。
    static func preview(seeded: Bool) -> ProfileStore {
        let container = SharedContainer(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("aether-preview-\(UUID().uuidString)"))
        let store = ProfileStore(container: container)
        if seeded {
            let text = "[Proxy]\nHK-01 = https, proxy.example.com, 443\n[Proxy Group]\nProxy = select, HK-01, DIRECT\n[Rule]\nFINAL,Proxy\n"
            if let entry = try? store.library.addProfile(
                name: "Main", text: text, source: .local, revision: contentHash(text), now: Date())
            {
                _ = try? RunBundle.commit(
                    profile: entry, profileText: text, modules: [], revision: "sha256:preview0000000000",
                    appVersion: "preview", now: Date(), container: container)
                _ = try? store.library.addProfile(
                    name: "Travel", text: text, source: .imported(url: "https://example.com/travel.conf"),
                    revision: contentHash(text), now: Date())
            }
            store.reload()
        }
        return store
    }
}

struct ProfileStoreError: Error, LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
