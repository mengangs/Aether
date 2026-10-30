import AetherDNS
import AetherFoundation
import AetherHTTP
import AetherOutbound
import NIOConcurrencyHelpers
import NIOCore

/// DoH / DoT 上游（docs/07 §4）：把 `AetherHTTP` 的加密 DNS 客户端接到 `DNSUpstream`。服务器域名经普通 DNS
/// （`dns-server`）解析，连接经 DIRECT；错误映射为 `DNS-` 码。
final class EncryptedDNSUpstream: DNSUpstream {
    let name: String
    let isSystem = false
    private let query: @Sendable ([UInt8]) -> EventLoopFuture<[UInt8]>
    private let resetConnection: @Sendable () -> Void

    /// 不是 DoH / DoT 或写法无效时返回 nil。`skipCertificateVerification` 对应 `encrypted-dns-skip-cert-verify`；
    /// `trustRoots` 只用于测试。
    init?(
        spec: DNSUpstreamSpec, eventLoop: any EventLoop, resolver: any ServerAddressResolver,
        skipCertificateVerification: Bool = false, trustRoots: [String] = []
    ) {
        var tls = TLSClientOptions()
        tls.skipCertificateVerification = skipCertificateVerification
        tls.additionalTrustRootsPEM = trustRoots
        switch spec {
        case .https(let url):
            guard
                let client = DNSOverHTTPSClient(url: url, resolver: resolver, tls: tls, eventLoop: eventLoop)
            else { return nil }
            name = url
            query = { client.query($0) }
            resetConnection = { client.reset() }
        case .tls(let url):
            guard let (host, port) = Self.hostPort(url, prefix: "tls://", defaultPort: 853) else { return nil }
            let client = DNSOverTLSClient(
                endpoint: EncryptedDNSEndpoint(host: host, port: port, tls: tls, resolver: resolver),
                eventLoop: eventLoop)
            name = url
            query = { client.query($0) }
            resetConnection = { client.reset() }
        default:
            return nil
        }
    }

    /// `tls://主机[:端口]`、`tls://[IPv6]:端口`。
    static func hostPort(_ url: String, prefix: String, defaultPort: UInt16) -> (String, UInt16)? {
        guard url.lowercased().hasPrefix(prefix) else { return nil }
        var rest = String(url.dropFirst(prefix.count))
        if let slash = rest.firstIndex(of: "/") {
            rest = String(rest[..<slash])
        }
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            let host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if tail.isEmpty { return (host, defaultPort) }
            guard tail.hasPrefix(":"), let port = UInt16(tail.dropFirst()), port > 0 else { return nil }
            return (host, port)
        }
        let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
        guard let host = parts.first, !host.isEmpty, parts.count <= 2 else { return nil }
        if parts.count == 2 {
            guard let port = UInt16(parts[1]), port > 0 else { return nil }
            return (String(host), port)
        }
        return (String(host), defaultPort)
    }

    func send(_ query: [UInt8], on eventLoop: any EventLoop) -> EventLoopFuture<[UInt8]> {
        self.query(query).hop(to: eventLoop).flatMapErrorThrowing { error in
            let code = NetworkErrorMapping.map(error).code
            if code == .netConnectTimeout {
                throw DNSError(.dnsTimeout, "\(self.name): \(error)")
            }
            throw DNSError(.dnsUpstreamUnreachable, "\(self.name): \(error)")
        }
    }

    func reset() {
        resetConnection()
    }
}

/// 在 `DNSService` 创建之后才能使用的服务器地址解析（DoH / DoT 的上游在 DNS 服务构造时创建）。
final class DeferredServerResolver: ServerAddressResolver, @unchecked Sendable {
    private let target = NIOLockedValueBox<DNSResolverAdapter?>(nil)

    func bind(_ dns: DNSService) {
        target.withLockedValue { $0 = DNSResolverAdapter(dns: dns, purpose: .server) }
    }

    func resolve(_ host: String, family: AddressFamily, on eventLoop: any EventLoop) -> EventLoopFuture<[IPAddress]> {
        guard let resolver = target.withLockedValue({ $0 }) else {
            return eventLoop.makeFailedFuture(NetworkError(.netResolutionFailed, "DNS service not ready"))
        }
        return resolver.resolve(host, family: family, on: eventLoop)
    }
}
