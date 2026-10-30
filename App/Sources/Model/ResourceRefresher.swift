import AetherControl
import AetherFoundation
import AetherIPC
import AetherProfile
import AetherRules
import Foundation
import Observation

/// App 侧的外部资源更新（docs/11 §5.3–§5.4）：用 `URLSession` 下载，缓存、条件请求、gzip、校验与退避由与隧道共用的
/// `ResourceUpdater` 完成。隧道运行时，更新了资源就发 `resourcesChanged`，由隧道重新加载。
///
/// 触发：导入或切换配置（该配置引用的全部资源）、App 启动与回到前台（到期的）、后台刷新（到期的，最多 30 秒）、
/// 外部资源页的"全部更新"（M3-14）。同一时间只运行一次更新，进行中时新的请求直接返回。
@MainActor
@Observable
final class ResourceRefresher {
    /// 后台刷新每次最多处理的时间（docs/11 §5.4）。
    static let backgroundTimeLimit: Duration = .seconds(30)

    let container: SharedContainer
    @ObservationIgnored let updater: ResourceUpdater
    private(set) var isUpdating = false
    /// 最近一次更新中各资源的结果（URL → 结果）；最多保留最近一次涉及的资源。
    private(set) var lastOutcomes: [String: ResourceUpdater.Outcome] = [:]

    init(container: SharedContainer, session: URLSession = .shared, appVersion: String) {
        self.container = container
        updater = ResourceUpdater(
            cache: ResourceCache(container: container),
            fetch: Self.fetch(session: session, userAgent: "Aether/\(appVersion)"), validate: Self.validate)
    }

    var cache: ResourceCache { updater.cache }

    /// 配置引用的远程资源（去重）。托管配置写入 `Profiles/`，随托管配置功能（M3-12）处理。
    nonisolated static func requests(_ resolved: ResolvedProfile) -> [ResourceRequest] {
        var seen = Set<String>()
        return resolved.externalResources.compactMap { reference in
            guard reference.isRemote, reference.kind != .managedProfile,
                let kind = ResourceKind(rawValue: reference.kind.rawValue),
                seen.insert(ResourceCache.normalize(reference.url)).inserted
            else { return nil }
            return ResourceRequest(
                url: reference.url, kind: kind,
                updateInterval: reference.updateInterval ?? resolved.general.resourceUpdateInterval)
        }
    }

    /// 当前运行包引用的资源；没有运行包时为空。
    func activeRequests() -> [ResourceRequest] {
        guard let bundle = try? RunBundle.loadActive(from: container) else { return [] }
        let resolved = ProfileResolver.resolve(
            profileText: bundle.profileText, fileName: bundle.manifest.profileName,
            modules: bundle.modules.map { ModuleInput(name: $0.name, text: $0.text) })
        return Self.requests(resolved)
    }

    /// 更新资源；`timeLimit` 到时取消（未完成的保持原状）。返回是否完成（未被取消）。
    @discardableResult
    func update(
        _ requests: [ResourceRequest], force: Bool, client: (any TunnelClientProtocol)?, timeLimit: Duration? = nil
    ) async -> Bool {
        guard !isUpdating, !requests.isEmpty else { return true }
        isUpdating = true
        defer { isUpdating = false }
        let updater = self.updater
        let work = Task { await updater.update(requests, force: force) }
        let timer = timeLimit.map { limit in
            Task {
                try? await Task.sleep(for: limit)
                work.cancel()
            }
        }
        let outcomes = await work.value
        timer?.cancel()
        lastOutcomes = Dictionary(zip(requests.map(\.url), outcomes), uniquingKeysWith: { _, last in last })
        let changed = zip(requests, outcomes).filter { $0.1 == .updated }.map(\.0.url)
        if !changed.isEmpty, let client {
            // 隧道未运行（IPC-001）时下次启动直接读取缓存。
            try? await client.resourcesChanged(urls: changed)
        }
        return !work.isCancelled
    }

    /// 到期资源的后台更新（启动、回到前台）。
    func refreshDue(client: (any TunnelClientProtocol)?) {
        let requests = activeRequests()
        Task { await update(requests, force: false, client: client) }
    }

    /// 后台刷新的最早执行时间：最近的到期时间（不早于 15 分钟后）；没有资源时为 nil。
    func nextRefreshDate() async -> Date? {
        guard let due = await updater.nextDueDate(activeRequests()) else { return nil }
        return max(due, Date().addingTimeInterval(15 * 60))
    }

    // MARK: - 下载与校验

    /// `URLSession` 下载：超时 20 秒（无数据）、带条件请求头、正文超过上限立即以 `RES-010` 停止。
    nonisolated static func fetch(session: URLSession, userAgent: String) -> ResourceUpdater.Fetch {
        { url, etag, lastModified, limit in
            guard let target = URL(string: url) else { throw ResourceError(.resDownloadFailed, "Invalid URL") }
            var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ResourceError(.resDownloadFailed, "Not an HTTP response")
            }
            let tooLarge = ResourceError(.resTooLarge, "Resource exceeds \(limit) bytes")
            if http.expectedContentLength > Int64(limit) { throw tooLarge }
            var body: [UInt8] = []
            body.reserveCapacity(Int(max(0, min(http.expectedContentLength, Int64(limit)))))
            for try await byte in bytes {
                guard body.count < limit else { throw tooLarge }
                body.append(byte)
            }
            return ResourceFetchResponse(
                status: http.statusCode, body: body, etag: http.value(forHTTPHeaderField: "ETag"),
                lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        }
    }

    /// 与隧道侧 `ResourceValidation`（`AetherEngine`，App 不能依赖）规则相同：基本校验之上，规则集与域名集至少 1 条有效条目。
    nonisolated static func validate(_ kind: ResourceKind, _ bytes: [UInt8]) -> (any AetherErrorProtocol)? {
        if let failure = kind.basicValidation(bytes) {
            return failure
        }
        let text = String(decoding: bytes, as: UTF8.self)
        switch kind {
        case .ruleSet:
            if case .failure(let error) = RuleSetParser.parse(text, name: "rule-set") { return error }
        case .domainSet:
            if case .failure(let error) = DomainSetLoader.load(text) { return error }
        default:
            break
        }
        return nil
    }
}
