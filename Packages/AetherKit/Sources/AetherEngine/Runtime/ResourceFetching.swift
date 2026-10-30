import AetherFoundation
import AetherHTTP
import AetherIPC
import AetherOutbound
import AetherProfile
import AetherRules
import Foundation
import NIOCore

extension Engine {
    /// 隧道侧的外部资源下载（docs/11 §5.3）：经 `[General] resource-fetch-policy`（默认 `DIRECT`）解析出的出站，
    /// 用 `HTTPFetch`（超时 20 秒、最多 5 次重定向）。策略在每次下载开始时解析；解析到 REJECT 以 `NET-022` 失败。
    public func fetchResource(
        _ url: String, etag: String?, lastModified: String?, limit: Int, userAgent: String,
        tls: TLSClientOptions = TLSClientOptions()
    ) async throws -> ResourceFetchResponse {
        let router = self.router
        let loop = router.eventLoop
        let dial = try await loop.submit { () throws -> HTTPFetch.Dial in
            let configuration = router.configuration
            let policy = configuration.general.resourceFetchPolicy
            let resolution = try router.dependencies.policies.resolve(policy, in: configuration)
            let connector: any OutboundConnector
            switch resolution.terminal {
            case .direct:
                connector = router.direct
            case .proxy(let node):
                guard let nodeConnector = node.connector else {
                    throw NetworkError(
                        .netPolicyUnavailable, node.unavailableReason ?? "Node \(node.name) is unavailable")
                }
                connector = nodeConnector
            case .reject:
                throw NetworkError(.netRejected, "resource-fetch-policy \(policy) resolves to a reject policy")
            case .group(let group):
                throw NetworkError(.netPolicyUnavailable, "Group \(group.name) did not resolve")
            }
            let resolver = router.serverResolver
            let logger = router.dependencies.logger
            return { destination, deadline in
                connector.connect(
                    to: destination,
                    context: DialContext(
                        flowID: FlowID(rawValue: 0), eventLoop: loop, deadline: deadline, serverResolver: resolver,
                        logger: logger))
            }
        }.get()
        var headers = [("User-Agent", userAgent)]
        if let etag {
            headers.append(("If-None-Match", etag))
        }
        if let lastModified {
            headers.append(("If-Modified-Since", lastModified))
        }
        let response = try await HTTPFetch.get(url, headers: headers, limit: limit, tls: tls, on: loop, dial: dial)
            .get()
        return ResourceFetchResponse(
            status: response.status, body: response.body, etag: response.header("ETag"),
            lastModified: response.header("Last-Modified"))
    }
}

/// 外部资源的内容校验（docs/11 §5.1）：在 `ResourceKind.basicValidation` 之上，规则集用 `RuleSetParser`、
/// 域名集用 `DomainSetLoader` 检查至少 1 条有效条目与条目上限。订阅（至少 1 个可解析节点）随 M3-09 的解析器加入。
/// App 侧（不能依赖本模块）有同样规则的实现。
public enum ResourceValidation {
    public static func validate(_ kind: ResourceKind, _ bytes: [UInt8]) -> (any AetherErrorProtocol)? {
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
