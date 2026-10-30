import AetherFoundation
import Foundation

/// 外部资源的种类与大小上限（docs/11 §5.1）。原始值与 `ExternalResourceRef.Kind` 一致。
public enum ResourceKind: String, Codable, Sendable, Hashable, CaseIterable {
    case ruleSet = "rule-set"
    case domainSet = "domain-set"
    case policyPath = "policy-path"
    case script
    case geoIPDatabase = "geoip-db"
    case ipASNDatabase = "ipasn-db"
    case mapLocalFile = "map-local"
    case managedProfile = "managed-profile"
    case remoteModule = "remote-module"

    /// 解压后的大小上限（下载的原始字节同样受此限制）。
    public var maxBytes: Int {
        switch self {
        case .ruleSet, .domainSet, .policyPath: return 32 << 20
        case .script, .managedProfile, .remoteModule: return 4 << 20
        case .geoIPDatabase, .ipASNDatabase: return 64 << 20
        case .mapLocalFile: return 8 << 20
        }
    }
}

/// 资源元数据（docs/11 §5.2）：与缓存文件同名的 `.json`。
public struct ResourceMetadata: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var url: String
    public var kind: ResourceKind
    /// 最近一次成功（含 304）的时间。
    public var fetchedAt: Date?
    public var lastAttemptAt: Date?
    /// 最近一次失败的错误（`RES-…: 说明`）；成功后清空。
    public var lastError: String?
    public var etag: String?
    public var lastModified: String?
    /// 缓存内容（解压后）的 SHA-256（十六进制）。
    public var sha256: String?
    public var size: Int?
    /// 秒。
    public var updateInterval: Double
    /// 连续失败次数（退避用）。
    public var failures = 0
    /// 退避期内不早于此时间重试。
    public var nextAttemptAt: Date?

    public init(url: String, kind: ResourceKind, updateInterval: Double) {
        self.url = url
        self.kind = kind
        self.updateInterval = updateInterval
    }

    /// 有可用的缓存内容。
    public var hasContent: Bool { fetchedAt != nil && sha256 != nil }
}

/// 一个要维护的资源。
public struct ResourceRequest: Sendable, Hashable {
    public var url: String
    public var kind: ResourceKind
    /// 秒。
    public var updateInterval: Double

    public init(url: String, kind: ResourceKind, updateInterval: Double) {
        self.url = url
        self.kind = kind
        self.updateInterval = updateInterval
    }
}

/// `Resources/` 下的缓存（docs/11 §3）：每个资源一个内容文件 `<键>.data` 与元数据 `<键>.meta.json`，
/// 键为规范化 URL 的 SHA-256 前 32 个十六进制字符；读取时核对元数据中的 URL（键冲突时视为没有缓存）。
/// 内容与元数据都以原子方式替换（两个写者并发时后完成者覆盖，docs/11 §2）。
public struct ResourceCache: Sendable {
    public let directory: URL

    public init(container: SharedContainer) {
        directory = container.resources
    }

    public init(directory: URL) {
        self.directory = directory
    }

    /// 规范化：协议与主机名小写、去掉默认端口与片段；其余（路径、查询串）原样保留。无法解析时原样返回。
    public static func normalize(_ url: String) -> String {
        guard var components = URLComponents(string: url), let scheme = components.scheme?.lowercased() else {
            return url
        }
        components.scheme = scheme
        if let host = components.percentEncodedHost {
            components.percentEncodedHost = host.lowercased()
        }
        if (scheme == "http" && components.port == 80) || (scheme == "https" && components.port == 443) {
            components.port = nil
        }
        components.fragment = nil
        return components.string ?? url
    }

    public static func key(for url: String) -> String {
        String(SHA2.sha256Hex(Array(normalize(url).utf8)).prefix(32))
    }

    public func contentsURL(for url: String) -> URL {
        directory.appendingPathComponent(Self.key(for: url) + ".data")
    }

    private func metadataURL(for url: String) -> URL {
        directory.appendingPathComponent(Self.key(for: url) + ".meta.json")
    }

    public func metadata(for url: String) -> ResourceMetadata? {
        guard let metadata = JSONStateFile.read(ResourceMetadata.self, from: metadataURL(for: url)),
            Self.normalize(metadata.url) == Self.normalize(url)
        else { return nil }
        return metadata
    }

    /// 缓存内容（元数据存在、URL 一致、有内容且长度与元数据一致时）。
    public func contents(for url: String) -> [UInt8]? {
        guard let metadata = metadata(for: url), metadata.hasContent,
            let data = try? Data(contentsOf: contentsURL(for: url)), data.count == metadata.size
        else { return nil }
        return Array(data)
    }

    public func write(metadata: ResourceMetadata) throws {
        try JSONStateFile.write(metadata, to: metadataURL(for: metadata.url))
    }

    /// 先写内容再写元数据：中途失败时元数据仍描述旧内容，长度不符的内容被 `contents(for:)` 视为没有缓存。
    public func write(contents: [UInt8], metadata: ResourceMetadata) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents).write(to: contentsURL(for: metadata.url), options: .atomic)
        try write(metadata: metadata)
    }

    public func remove(_ url: String) {
        try? FileManager.default.removeItem(at: contentsURL(for: url))
        try? FileManager.default.removeItem(at: metadataURL(for: url))
    }

    /// 全部元数据（外部资源页），按 URL 排序。
    public func all() -> [ResourceMetadata] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.lastPathComponent.hasSuffix(".meta.json") }
            .compactMap { JSONStateFile.read(ResourceMetadata.self, from: $0) }
            .sorted { $0.url < $1.url }
    }
}

/// 下载的应答。
public struct ResourceFetchResponse: Sendable {
    public var status: Int
    public var body: [UInt8]
    public var etag: String?
    public var lastModified: String?

    public init(status: Int, body: [UInt8], etag: String? = nil, lastModified: String? = nil) {
        self.status = status
        self.body = body
        self.etag = etag
        self.lastModified = lastModified
    }
}

/// 外部资源的下载与更新（docs/11 §5.3–§5.4），App 与隧道共用：下载方式与内容校验由调用方注入。
///
/// - 条件请求：有缓存时带上次的 `ETag` / `Last-Modified`，`304` 只更新 `fetchedAt`；
/// - URL 路径以 `.gz` 结尾或内容以 `1f 8b` 开头时解压（`Inflate`，解压后同样受上限约束）；
/// - 校验通过才原子替换缓存；失败保留旧缓存，记录 `lastError`，按 5 分钟起、翻倍、上限 1 小时退避；
/// - 到期：没有缓存或 `fetchedAt + updateInterval` 已过，且不在退避期内；`force` 时忽略这两项；
/// - `downloadLimit` 小于种类上限时（隧道的内存预算，docs/02 §6），超出它但未超出种类上限的资源结果为
///   `deferred`，不改动元数据，留给 App 更新；
/// - 同时下载最多 `concurrency` 个（默认 4）。
public actor ResourceUpdater {
    /// 下载：`limit` 为正文上限，超出时应以 `RES-010`（`ResourceError(.resTooLarge, …)`）失败而不继续读取。
    public typealias Fetch =
        @Sendable (_ url: String, _ etag: String?, _ lastModified: String?, _ limit: Int) async throws
        -> ResourceFetchResponse
    /// 校验解压后的内容；返回 nil 表示通过。
    public typealias Validate = @Sendable (ResourceKind, [UInt8]) -> (any AetherErrorProtocol)?

    public enum Outcome: Sendable, Equatable {
        /// 内容已替换。
        case updated
        /// `304` 或内容与缓存相同。
        case notModified
        /// 未到期，或更新被取消。
        case skipped
        /// 超出 `downloadLimit`，留给 App。
        case deferred
        case failed(code: AetherErrorCode, message: String)
    }

    public static let initialBackoff: TimeInterval = 5 * 60
    public static let maxBackoff: TimeInterval = 60 * 60

    public let cache: ResourceCache
    private let fetch: Fetch
    private let validate: Validate
    private let clock: @Sendable () -> Date
    private let downloadLimit: Int
    private let concurrency: Int

    public init(
        cache: ResourceCache, fetch: @escaping Fetch, validate: @escaping Validate = { $0.basicValidation($1) },
        clock: @escaping @Sendable () -> Date = { Date() }, downloadLimit: Int = .max, concurrency: Int = 4
    ) {
        self.cache = cache
        self.fetch = fetch
        self.validate = validate
        self.clock = clock
        self.downloadLimit = downloadLimit
        self.concurrency = max(1, concurrency)
    }

    public static func isDue(_ metadata: ResourceMetadata?, interval: Double, now: Date) -> Bool {
        guard let metadata else { return true }
        if let next = metadata.nextAttemptAt, next > now {
            return false
        }
        guard metadata.hasContent, let fetched = metadata.fetchedAt else { return true }
        return fetched.addingTimeInterval(interval) <= now
    }

    /// 最早的到期时间（后台刷新的最早执行时间，docs/11 §5.4）；没有资源时为 nil。
    public func nextDueDate(_ requests: [ResourceRequest]) -> Date? {
        requests.map { request -> Date in
            guard let metadata = cache.metadata(for: request.url) else { return .distantPast }
            if let next = metadata.nextAttemptAt, metadata.failures > 0 { return next }
            guard metadata.hasContent, let fetched = metadata.fetchedAt else { return .distantPast }
            return fetched.addingTimeInterval(request.updateInterval)
        }.min()
    }

    /// 更新到期（或 `force` 时全部）的资源，返回每个资源的结果（与 `requests` 同序）。所在任务被取消时不再开始新的下载。
    public func update(_ requests: [ResourceRequest], force: Bool = false) async -> [Outcome] {
        var outcomes = [Outcome](repeating: .skipped, count: requests.count)
        let now = clock()
        let due = requests.indices.filter { index in
            force
                || Self.isDue(
                    cache.metadata(for: requests[index].url), interval: requests[index].updateInterval, now: now)
        }
        var next = due.makeIterator()
        await withTaskGroup(of: (Int, Outcome).self) { group in
            for _ in 0..<concurrency {
                guard let index = next.next() else { break }
                group.addTask { (index, await self.updateOne(requests[index])) }
            }
            while let (index, outcome) = await group.next() {
                outcomes[index] = outcome
                // 取消后不再开始新的下载（未开始的保持 `skipped`）。
                if !Task.isCancelled, let following = next.next() {
                    group.addTask { (following, await self.updateOne(requests[following])) }
                }
            }
        }
        return outcomes
    }

    private func updateOne(_ request: ResourceRequest) async -> Outcome {
        var metadata =
            cache.metadata(for: request.url)
            ?? ResourceMetadata(url: request.url, kind: request.kind, updateInterval: request.updateInterval)
        metadata.kind = request.kind
        metadata.updateInterval = request.updateInterval
        metadata.lastAttemptAt = clock()
        let limit = min(request.kind.maxBytes, downloadLimit)
        let deferrable = limit < request.kind.maxBytes
        do {
            let hasContent = cache.contents(for: request.url) != nil
            let response = try await fetch(
                request.url, hasContent ? metadata.etag : nil, hasContent ? metadata.lastModified : nil, limit)
            if response.status == 304, hasContent {
                return succeed(&metadata, outcome: .notModified)
            }
            guard (200..<300).contains(response.status) else {
                throw ResourceError(.resDownloadFailed, "HTTP \(response.status)")
            }
            guard response.body.count <= limit else { throw Self.tooLarge(limit) }
            var body = response.body
            let path = URLComponents(string: request.url)?.path.lowercased() ?? ""
            if path.hasSuffix(".gz") || Inflate.isGzip(body) {
                do {
                    body = try Inflate.gunzip(body, limit: limit)
                } catch .tooLarge {
                    throw Self.tooLarge(limit)
                } catch {
                    throw ResourceError(.resDecompressionFailed, "Invalid gzip data (\(error))")
                }
            }
            if let failure = validate(request.kind, body) {
                throw failure
            }
            let digest = SHA2.sha256Hex(body)
            metadata.etag = response.etag
            metadata.lastModified = response.lastModified
            if digest == metadata.sha256, hasContent {
                return succeed(&metadata, outcome: .notModified)
            }
            metadata.sha256 = digest
            metadata.size = body.count
            metadata.fetchedAt = clock()
            metadata.lastError = nil
            metadata.failures = 0
            metadata.nextAttemptAt = nil
            try cache.write(contents: body, metadata: metadata)
            return .updated
        } catch {
            // 被取消（后台刷新到时）不算失败，不改动元数据。
            if Task.isCancelled || error is CancellationError {
                return .skipped
            }
            // 非 `RES` 类的错误（网络、TLS）归为下载失败，原错误码保留在说明里。
            let aether = error as? any AetherErrorProtocol
            let isResourceCode = aether?.code.rawValue.hasPrefix("RES-") == true
            let code = isResourceCode ? aether?.code ?? .resDownloadFailed : .resDownloadFailed
            if deferrable, code == .resTooLarge {
                return .deferred
            }
            let message =
                isResourceCode
                ? aether?.debugDetails ?? "\(error)"
                : aether.map { "\($0.code.rawValue): \($0.debugDetails)" } ?? "\(error)"
            metadata.failures += 1
            let backoff = min(Self.initialBackoff * pow(2, Double(min(metadata.failures, 16) - 1)), Self.maxBackoff)
            metadata.nextAttemptAt = clock().addingTimeInterval(backoff)
            metadata.lastError = "\(code.rawValue): \(message)"
            try? cache.write(metadata: metadata)
            return .failed(code: code, message: message)
        }
    }

    private static func tooLarge(_ limit: Int) -> ResourceError {
        ResourceError(.resTooLarge, "Resource exceeds \(limit) bytes")
    }

    private func succeed(_ metadata: inout ResourceMetadata, outcome: Outcome) -> Outcome {
        metadata.fetchedAt = clock()
        metadata.lastError = nil
        metadata.failures = 0
        metadata.nextAttemptAt = nil
        try? cache.write(metadata: metadata)
        return outcome
    }
}

extension ResourceKind {
    /// 与格式解析无关的校验（docs/11 §5.1）：文本类必须是非空 UTF-8；MMDB 必须带元数据标记
    /// `\xAB\xCD\xEFMaxMind.com`（在最后 128 KiB 内）；Map Local 文件不校验。规则集、域名集、订阅与配置的
    /// 内容解析由调用方在此之上追加。
    public func basicValidation(_ bytes: [UInt8]) -> ResourceError? {
        switch self {
        case .mapLocalFile:
            return nil
        case .geoIPDatabase, .ipASNDatabase:
            let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
            let window = bytes.suffix(128 * 1024)
            guard window.count >= marker.count else {
                return ResourceError(.resInvalidContent, "Not a MaxMind DB file")
            }
            var index = window.endIndex - marker.count
            while index >= window.startIndex {
                if window[index..<(index + marker.count)].elementsEqual(marker) { return nil }
                index -= 1
            }
            return ResourceError(.resInvalidContent, "Not a MaxMind DB file (metadata marker missing)")
        case .ruleSet, .domainSet, .policyPath, .script, .managedProfile, .remoteModule:
            guard String(bytes: bytes, encoding: .utf8) != nil else {
                return ResourceError(.resInvalidContent, "Not UTF-8 text")
            }
            guard bytes.contains(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) else {
                return ResourceError(.resInvalidContent, "Empty resource")
            }
            return nil
        }
    }
}
