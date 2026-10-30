import AetherFoundation
import AetherTestSupport
import Foundation
import Testing

@testable import AetherIPC

/// 替身下载器：按 URL 返回预设应答，记录收到的条件请求头与上限。
private final class FakeOrigin: Sendable {
    struct Request: Sendable, Equatable {
        var url: String
        var etag: String?
        var lastModified: String?
        var limit: Int
    }

    let responses = Locked<[String: Result<ResourceFetchResponse, ResourceError>]>([:])
    let requests = Locked<[Request]>([])
    let active = Locked(0)
    let maxActive = Locked(0)

    func set(_ url: String, _ response: ResourceFetchResponse) {
        responses.withLock { $0[url] = .success(response) }
    }

    func fail(_ url: String, _ error: ResourceError) {
        responses.withLock { $0[url] = .failure(error) }
    }

    var fetch: ResourceUpdater.Fetch {
        { url, etag, lastModified, limit in
            self.requests.withLock {
                $0.append(Request(url: url, etag: etag, lastModified: lastModified, limit: limit))
            }
            let now = self.active.withLock { value -> Int in
                value += 1
                return value
            }
            self.maxActive.withLock { $0 = max($0, now) }
            defer { self.active.withLock { $0 -= 1 } }
            for _ in 0..<5 { await Task.yield() }
            try Task.checkCancellation()
            guard let response = self.responses.withLock({ $0[url] }) else {
                return ResourceFetchResponse(status: 404, body: [])
            }
            let value = try response.get()
            guard value.body.count <= limit else { throw ResourceError(.resTooLarge, "over \(limit)") }
            return value
        }
    }
}

private struct Harness {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aether-resources-\(UUID())")
    let origin = FakeOrigin()
    let now = Locked(Date(timeIntervalSince1970: 1_800_000_000))

    var cache: ResourceCache { ResourceCache(directory: directory) }

    func updater(downloadLimit: Int = .max, concurrency: Int = 4) -> ResourceUpdater {
        let now = self.now
        return ResourceUpdater(
            cache: cache, fetch: origin.fetch, clock: { now.withLock { $0 } }, downloadLimit: downloadLimit,
            concurrency: concurrency)
    }

    func advance(_ seconds: TimeInterval) {
        now.withLock { $0 = $0.addingTimeInterval(seconds) }
    }

    var date: Date { now.withLock { $0 } }
}

@Suite("External resources: cache and updater (11 §5)")
struct ResourceStoreTests {
    static let url = "https://example.com/rules/ads.list"
    static let request = ResourceRequest(url: url, kind: .ruleSet, updateInterval: 86400)

    @Test("The first download writes <key>.data and <key>.meta.json; the key is SHA-256 of the normalized URL")
    func firstDownload() async throws {
        let harness = Harness()
        harness.origin.set(
            Self.url, ResourceFetchResponse(status: 200, body: Array("DOMAIN,example.com\n".utf8), etag: "\"v1\""))
        let outcomes = await harness.updater().update([Self.request])
        #expect(outcomes == [.updated])
        #expect(harness.cache.contents(for: Self.url) == Array("DOMAIN,example.com\n".utf8))
        let metadata = try #require(harness.cache.metadata(for: Self.url))
        #expect(metadata.etag == "\"v1\"")
        #expect(metadata.size == 19)
        #expect(metadata.sha256 == SHA2.sha256Hex(Array("DOMAIN,example.com\n".utf8)))
        #expect(metadata.fetchedAt == harness.date)
        #expect(metadata.kind == .ruleSet)
        let key = ResourceCache.key(for: Self.url)
        #expect(key.count == 32)
        let files = try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).sorted()
        #expect(files == [key + ".data", key + ".meta.json"])
        #expect(harness.cache.all().map(\.url) == [Self.url])
        // 规范化：协议与主机大小写、默认端口与片段不影响键。
        #expect(ResourceCache.key(for: "HTTPS://Example.COM:443/rules/ads.list#top") == key)
        #expect(ResourceCache.key(for: "https://example.com/rules/ADS.list") != key)
        #expect(harness.cache.contents(for: "https://example.com:443/rules/ads.list") != nil)
    }

    @Test("Not due → skipped; due → conditional request; 304 and identical content only refresh fetchedAt")
    func conditional() async throws {
        let harness = Harness()
        harness.origin.set(
            Self.url,
            ResourceFetchResponse(
                status: 200, body: Array("DOMAIN,example.com".utf8), etag: "\"v1\"",
                lastModified: "Thu, 29 Oct 2026 10:00:00 GMT"))
        let updater = harness.updater()
        #expect(await updater.update([Self.request]) == [.updated])
        harness.advance(3600)
        #expect(await updater.update([Self.request]) == [.skipped])
        #expect(harness.origin.requests.withLock { $0.count } == 1)
        #expect(await updater.nextDueDate([Self.request]) == harness.date.addingTimeInterval(86400 - 3600))

        harness.advance(86400)
        harness.origin.set(Self.url, ResourceFetchResponse(status: 304, body: []))
        #expect(await updater.update([Self.request]) == [.notModified])
        let last = try #require(harness.origin.requests.withLock { $0.last })
        #expect(last.etag == "\"v1\"")
        #expect(last.lastModified == "Thu, 29 Oct 2026 10:00:00 GMT")
        #expect(last.limit == ResourceKind.ruleSet.maxBytes)
        #expect(harness.cache.metadata(for: Self.url)?.fetchedAt == harness.date)
        #expect(harness.cache.contents(for: Self.url) == Array("DOMAIN,example.com".utf8))

        // force 忽略到期；内容相同视为未修改。
        harness.origin.set(Self.url, ResourceFetchResponse(status: 200, body: Array("DOMAIN,example.com".utf8)))
        #expect(await updater.update([Self.request], force: true) == [.notModified])
        // 没有缓存时不带条件头，304 视为失败。
        let other = ResourceRequest(url: "https://example.net/list", kind: .domainSet, updateInterval: 600)
        harness.origin.set(other.url, ResourceFetchResponse(status: 304, body: []))
        #expect(await updater.update([other]) == [.failed(code: .resDownloadFailed, message: "HTTP 304")])
        #expect(harness.origin.requests.withLock { $0.last?.etag } == nil)
    }

    @Test("gzip is detected by the .gz suffix or the magic bytes; corrupt gzip keeps the old cache")
    func gzip() async throws {
        let harness = Harness()
        let compressed = Array(try Fixtures.data("compression/dynamic.gz"))
        let expected = Array((0..<2000).map { "DOMAIN-SUFFIX,host\($0).example.com\n" }.joined().utf8)
        let byMagic = ResourceRequest(url: "https://example.com/a.list", kind: .ruleSet, updateInterval: 600)
        let bySuffix = ResourceRequest(url: "https://example.com/b.list.gz", kind: .domainSet, updateInterval: 600)
        harness.origin.set(byMagic.url, ResourceFetchResponse(status: 200, body: compressed))
        harness.origin.set(bySuffix.url, ResourceFetchResponse(status: 200, body: compressed))
        let updater = harness.updater()
        #expect(await updater.update([byMagic, bySuffix]) == [.updated, .updated])
        #expect(harness.cache.contents(for: byMagic.url) == expected)
        #expect(harness.cache.metadata(for: bySuffix.url)?.size == expected.count)

        var corrupt = compressed
        corrupt[corrupt.count - 6] ^= 0xFF
        harness.origin.set(bySuffix.url, ResourceFetchResponse(status: 200, body: corrupt))
        let outcome = await updater.update([bySuffix], force: true)
        guard case .failed(let code, _) = outcome.first else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(code == .resDecompressionFailed)
        #expect(harness.cache.contents(for: bySuffix.url) == expected)
    }

    @Test("Validation and HTTP failures keep the old cache and back off 5 min → 10 min → … → 1 h")
    func backoff() async throws {
        let harness = Harness()
        harness.origin.set(Self.url, ResourceFetchResponse(status: 200, body: Array("DOMAIN,example.com".utf8)))
        let updater = harness.updater()
        #expect(await updater.update([Self.request]) == [.updated])
        harness.advance(86400)
        harness.origin.set(Self.url, ResourceFetchResponse(status: 200, body: Array(" \n\t\n".utf8)))
        #expect(
            await updater.update([Self.request]) == [.failed(code: .resInvalidContent, message: "Empty resource")])
        var metadata = try #require(harness.cache.metadata(for: Self.url))
        #expect(metadata.lastError == "RES-003: Empty resource")
        #expect(metadata.failures == 1)
        #expect(metadata.nextAttemptAt == harness.date.addingTimeInterval(300))
        #expect(harness.cache.contents(for: Self.url) == Array("DOMAIN,example.com".utf8))
        #expect(await updater.nextDueDate([Self.request]) == harness.date.addingTimeInterval(300))

        harness.advance(299)
        #expect(await updater.update([Self.request]) == [.skipped])
        var delays: [TimeInterval] = []
        harness.origin.set(Self.url, ResourceFetchResponse(status: 503, body: []))
        for _ in 0..<6 {
            harness.advance(3600)
            #expect(await updater.update([Self.request]) == [.failed(code: .resDownloadFailed, message: "HTTP 503")])
            metadata = try #require(harness.cache.metadata(for: Self.url))
            delays.append(try #require(metadata.nextAttemptAt).timeIntervalSince(harness.date))
        }
        #expect(delays == [600, 1200, 2400, 3600, 3600, 3600])

        // 成功后清除错误与退避。
        harness.advance(3600)
        harness.origin.set(Self.url, ResourceFetchResponse(status: 200, body: Array("DOMAIN,example.org".utf8)))
        #expect(await updater.update([Self.request]) == [.updated])
        metadata = try #require(harness.cache.metadata(for: Self.url))
        #expect(metadata.lastError == nil)
        #expect(metadata.failures == 0)
        #expect(metadata.nextAttemptAt == nil)
    }

    @Test("Over the kind limit fails with RES-010; over a smaller download limit is deferred without touching metadata")
    func limits() async throws {
        let harness = Harness()
        let script = ResourceRequest(url: "https://example.com/s.js", kind: .script, updateInterval: 600)
        harness.origin.set(
            script.url, ResourceFetchResponse(status: 200, body: [UInt8](repeating: 0x61, count: (4 << 20) + 1)))
        let outcomes = await harness.updater().update([script])
        guard case .failed(let code, _) = outcomes.first else {
            Issue.record("expected a failure, got \(outcomes)")
            return
        }
        #expect(code == .resTooLarge)
        #expect(harness.cache.metadata(for: script.url)?.failures == 1)

        let big = ResourceRequest(url: "https://example.com/big.list", kind: .domainSet, updateInterval: 600)
        harness.origin.set(
            big.url,
            ResourceFetchResponse(status: 200, body: Array(".example.com\n".utf8) + [UInt8](repeating: 0x20, count: 64))
        )
        #expect(await harness.updater(downloadLimit: 32).update([big]) == [.deferred])
        #expect(harness.cache.metadata(for: big.url) == nil)
        #expect(harness.origin.requests.withLock { $0.last?.limit } == 32)
        // gzip 解压后超出下载上限同样留给 App。
        let compressed = Array(try Fixtures.data("compression/dynamic.gz"))
        harness.origin.set(big.url, ResourceFetchResponse(status: 200, body: compressed))
        #expect(await harness.updater(downloadLimit: compressed.count).update([big]) == [.deferred])
        #expect(await harness.updater().update([big]) == [.updated])
    }

    @Test("Downloads run at most `concurrency` at a time and outcomes keep the request order")
    func concurrency() async {
        let harness = Harness()
        let requests = (0..<8).map {
            ResourceRequest(url: "https://example.com/\($0).list", kind: .ruleSet, updateInterval: 600)
        }
        for (index, request) in requests.enumerated() where index != 3 {
            harness.origin.set(request.url, ResourceFetchResponse(status: 200, body: Array("DOMAIN,a\(index)".utf8)))
        }
        harness.origin.fail(requests[5].url, ResourceError(.resDownloadFailed, "timed out"))
        let outcomes = await harness.updater(concurrency: 2).update(requests)
        #expect(outcomes[3] == .failed(code: .resDownloadFailed, message: "HTTP 404"))
        #expect(outcomes[5] == .failed(code: .resDownloadFailed, message: "timed out"))
        #expect(outcomes.enumerated().filter { $0.offset != 3 && $0.offset != 5 }.allSatisfy { $0.element == .updated })
        #expect(harness.origin.maxActive.withLock { $0 } <= 2)
    }

    @Test("A cancelled update leaves metadata untouched and reports skipped")
    func cancellation() async {
        let harness = Harness()
        harness.origin.set(Self.url, ResourceFetchResponse(status: 200, body: Array("DOMAIN,example.com".utf8)))
        let updater = harness.updater()
        let task = Task { await updater.update([Self.request]) }
        task.cancel()
        #expect(await task.value == [.skipped])
        #expect(harness.cache.metadata(for: Self.url) == nil)
    }

    @Test("Basic validation: UTF-8 text, MMDB metadata marker, Map Local accepts anything")
    func basicValidation() {
        #expect(ResourceKind.script.basicValidation(Array("console.log(1)".utf8)) == nil)
        #expect(ResourceKind.script.basicValidation([0xFF, 0xFE, 0x41])?.code == .resInvalidContent)
        #expect(ResourceKind.ruleSet.basicValidation([])?.code == .resInvalidContent)
        let marker: [UInt8] = [0xAB, 0xCD, 0xEF] + Array("MaxMind.com".utf8)
        #expect(ResourceKind.geoIPDatabase.basicValidation([UInt8](repeating: 0, count: 100) + marker + [0xE0]) == nil)
        #expect(ResourceKind.ipASNDatabase.basicValidation(Array("not a database".utf8))?.code == .resInvalidContent)
        #expect(ResourceKind.ipASNDatabase.basicValidation([])?.code == .resInvalidContent)
        #expect(ResourceKind.mapLocalFile.basicValidation([0xFF]) == nil)
    }
}
