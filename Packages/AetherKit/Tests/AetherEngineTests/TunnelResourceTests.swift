import AetherFoundation
import AetherIPC
import AetherStore
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import AetherEngine

/// 回环资源服务端：按路径返回 `bodies` 中的内容（带 ETag），没有的路径返回 404；记录请求行与 User-Agent。
private final class ResourceOriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    let bodies: NIOLockedValueBox<[String: String]>
    let requests: NIOLockedValueBox<[String]>
    private var buffer = ""

    init(bodies: NIOLockedValueBox<[String: String]>, requests: NIOLockedValueBox<[String]>) {
        self.bodies = bodies
        self.requests = requests
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        buffer += String(decoding: unwrapInboundIn(data).readableBytesView, as: UTF8.self)
        guard let end = buffer.range(of: "\r\n\r\n") else { return }
        let lines = buffer[..<end.lowerBound].components(separatedBy: "\r\n")
        let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
        let agent = lines.first { $0.hasPrefix("User-Agent: ") }?.dropFirst(12) ?? ""
        requests.withLockedValue { $0.append("\(path) \(agent)") }
        let reply: String
        if let body = bodies.withLockedValue({ $0[path] }) {
            reply =
                "HTTP/1.1 200 OK\r\nETag: \"\(body.utf8.count)\"\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        } else {
            reply = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        }
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: reply)), promise: nil)
        context.close(promise: nil)
    }
}

extension TunnelRuntime {
    /// 因资源变化的重载已发生 `count` 次且已完成。
    fileprivate func reloadedForResources(_ count: Int) -> Bool {
        resourceReloadCount == count && state == .running
    }
}

@Suite("Tunnel-side external resource updates (11 §5.3–§5.4)")
struct TunnelResourceTests {
    @Test(
        "Maintenance downloads due resources through resource-fetch-policy, reloads once, and IPC forces or signals updates"
    )
    func updates() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bodies = NIOLockedValueBox<[String: String]>([
            "/ads.list": "DOMAIN-SUFFIX,ads.example.com\n", "/hosts.txt": ".tracker.example.net\n",
        ])
        let requests = NIOLockedValueBox<[String]>([])
        let origin = try await LoopbackTCPServer.start(group: group) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(
                    ResourceOriginHandler(bodies: bodies, requests: requests))
            }
        }
        let base = "http://127.0.0.1:\(origin.port)"
        let fixture = ContainerFixture()
        defer { fixture.remove() }
        try fixture.commit(
            profile: """
                [General]
                dns-server = 192.0.2.53
                geoip-maxmind-url = \(base)/country.mmdb

                [Rule]
                RULE-SET,\(base)/ads.list,REJECT
                DOMAIN-SET,\(base)/hosts.txt,REJECT,update-interval=3600
                RULE-SET,\(base)/ads.list,DIRECT
                FINAL,DIRECT
                """, revision: "sha256:resources00000001")
        let runtime = fixture.runtime(notifications: .init([]), reasserts: .init([])) { hooks in
            hooks.appVersion = "9.9.9"
            hooks.sleep = { _ in }
        }
        _ = try await runtime.start()
        await runtime.didStart()
        // 去重；MMDB 只由 App 更新。
        #expect(await runtime.resourceRequests.map(\.url) == ["\(base)/ads.list", "\(base)/hosts.txt"])
        #expect(await runtime.resourceRequests.map(\.updateInterval) == [86400, 3600])

        let cache = ResourceCache(container: fixture.container)
        await runtime.maintenance()
        #expect(
            await Poll.until {
                cache.contents(for: "\(base)/ads.list") != nil && cache.contents(for: "\(base)/hosts.txt") != nil
            })
        // 计数与进入 reloading 在同一个 actor 回合内：计数为 1 且状态回到 running 即重载完成（重载中的 IPC 返回 IPC-012）。
        #expect(await Poll.until { await runtime.reloadedForResources(1) })
        #expect(requests.withLockedValue { $0 }.sorted() == ["/ads.list Aether/9.9.9", "/hosts.txt Aether/9.9.9"])
        #expect(cache.metadata(for: "\(base)/hosts.txt")?.etag == "\"21\"")

        // 15 分钟内不再检查。
        await runtime.maintenance()
        // updateResources 忽略到期时间；未引用的 URL 不下载。内容未变不重载。
        let payload = try await runtime.handle(.updateResources(urls: ["\(base)/hosts.txt", "\(base)/other.list"]))
        guard case .resourceTask(let task) = payload else {
            Issue.record("unexpected payload \(payload)")
            return
        }
        #expect(task.count == 1)
        #expect(await Poll.until { requests.withLockedValue { $0.count } == 3 })
        // 失败：保留旧缓存，元数据记录错误，日志簿写入 RES 码。
        bodies.withLockedValue { $0["/ads.list"] = nil }
        _ = try await runtime.handle(.updateResources(urls: nil))
        #expect(await Poll.until { cache.metadata(for: "\(base)/ads.list")?.lastError == "RES-001: HTTP 404" })
        #expect(cache.contents(for: "\(base)/ads.list") == Array("DOMAIN-SUFFIX,ads.example.com\n".utf8))
        #expect(await runtime.resourceReloadCount == 1)

        // App 更新了被引用的资源（含 MMDB）才重载。
        _ = try await runtime.handle(.resourcesChanged(urls: ["https://example.org/unrelated.list"]))
        #expect(await runtime.resourceReloadCount == 1)
        _ = try await runtime.handle(.resourcesChanged(urls: ["\(base)/country.mmdb"]))
        #expect(await Poll.until { await runtime.reloadedForResources(2) })

        await runtime.stop(reason: "test")
        await #expect(throws: IPCError.self) { _ = try await runtime.handle(.updateResources(urls: nil)) }
        let database = try AetherDatabase.open(directory: fixture.container.database)
        let logbook = try await database.recentLogbook()
        #expect(
            logbook.contains { $0.category == .resource && $0.code == "RES-001" && $0.message.contains("127.0.0.1") })
        #expect(logbook.contains { $0.category == .resource && $0.message.contains("Updated 2 external resource(s)") })
        try await origin.close()
        try await group.shutdownGracefully()
    }
}
