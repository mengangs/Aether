import AetherFoundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// 一组上游（docs/07 §4.2）：同时向全部上游查询，采用第一个 NOERROR 或 NXDOMAIN 应答；SERVFAIL、REFUSED、
/// 超时则等待其它上游。整体超时 5 秒。记录每个上游的近期耗时与失败次数。
///
/// 绑定到数据面 EventLoop：`query` 与统计只在该 EventLoop 上访问。
public final class DNSUpstreamGroup: @unchecked Sendable {
    public let identifier: String
    public let upstreams: [any DNSUpstream]
    public let eventLoop: any EventLoop
    public let overallTimeout: TimeAmount
    private var statistics: [String: DNSUpstreamStatistics]

    public init(
        identifier: String, upstreams: [any DNSUpstream], eventLoop: any EventLoop,
        overallTimeout: TimeAmount = .seconds(5)
    ) {
        self.identifier = identifier
        self.upstreams = upstreams
        self.eventLoop = eventLoop
        self.overallTimeout = overallTimeout
        statistics = Dictionary(
            upstreams.map { ($0.name, DNSUpstreamStatistics(name: $0.name)) }, uniquingKeysWith: { first, _ in first })
    }

    /// 各上游的统计（按配置顺序）。
    public var upstreamStatistics: [DNSUpstreamStatistics] {
        eventLoop.preconditionInEventLoop()
        return upstreams.compactMap { statistics[$0.name] }
    }

    /// 是否包含 `system` 上游。
    public var containsSystem: Bool {
        upstreams.contains { $0.isSystem }
    }

    /// 并发查询。全部上游都失败时：若收到过应答（如 SERVFAIL）则返回最后一个应答，否则以 `DNSError` 失败。
    public func query(_ query: [UInt8]) -> EventLoopFuture<DNSUpstreamAnswer> {
        eventLoop.preconditionInEventLoop()
        guard !upstreams.isEmpty else {
            return eventLoop.makeFailedFuture(DNSError(.dnsUpstreamUnreachable, "No upstream configured"))
        }
        let promise = eventLoop.makePromise(of: DNSUpstreamAnswer.self)
        let started = eventLoop.now
        var pending = upstreams.count
        var fallback: DNSUpstreamAnswer?
        var lastError: (any Error)?
        var finished = false
        let timer = eventLoop.assumeIsolated().scheduleTask(in: overallTimeout) {
            guard !finished else { return }
            finished = true
            if let fallback {
                promise.succeed(fallback)
            } else {
                promise.fail(DNSError(.dnsTimeout, "No upstream answered within \(self.overallTimeout)"))
            }
        }
        for upstream in upstreams {
            upstream.send(query, on: eventLoop).hop(to: eventLoop).assumeIsolated().whenComplete { result in
                pending -= 1
                let duration = self.eventLoop.now - started
                switch result {
                case .success(let bytes):
                    do {
                        let scanned = try DNSWire.scan(bytes)
                        let answer = DNSUpstreamAnswer(
                            response: bytes, scanned: scanned, upstream: upstream.name, fromSystem: upstream.isSystem,
                            duration: duration)
                        let code = scanned.message.header.responseCode
                        if code == .noError || code == .nameError {
                            self.statistics[upstream.name]?.recordSuccess(duration)
                            if !finished {
                                finished = true
                                timer.cancel()
                                promise.succeed(answer)
                            }
                            return
                        }
                        self.statistics[upstream.name]?.recordFailure(
                            DNSError(.dnsServerFailure, "\(code)"))
                        fallback = answer
                    } catch {
                        let failure = DNSError(.dnsMalformedResponse, "\(error)")
                        self.statistics[upstream.name]?.recordFailure(failure)
                        lastError = failure
                    }
                case .failure(let error):
                    self.statistics[upstream.name]?.recordFailure(error)
                    lastError = error
                }
                if pending == 0, !finished {
                    finished = true
                    timer.cancel()
                    if let fallback {
                        promise.succeed(fallback)
                    } else {
                        promise.fail(lastError ?? DNSError(.dnsUpstreamUnreachable, "All upstreams failed"))
                    }
                }
            }
        }
        return promise.futureResult
    }
}

// MARK: - system

/// 系统 DNS 上游（docs/07 §4.1）：物理网络下发的 DNS 服务器由平台注入（隧道用 libresolv，`aether-cli` 读
/// `/etc/resolv.conf`），排除 TUN 与 Fake IP 段内的地址后并发查询；列表为空时回退为线程池中的 `getaddrinfo`
/// （只能解析 A / AAAA，TTL 取 60 秒）。网络变化时调用 `refresh()` 重新读取。
public final class SystemDNSUpstream: DNSUpstream {
    public let name = "system"
    public let isSystem = true

    private let provider: @Sendable () -> [IPAddress]
    private let excluded: [CIDR]
    private let blockingPool: NIOThreadPool?
    private let servers: NIOLockedValueBox<[UDPDNSUpstream]?> = NIOLockedValueBox(nil)

    /// - Parameters:
    ///   - provider: 返回系统 DNS 服务器地址（端口 53）。
    ///   - excluded: 要排除的地址段（Fake IP 段、TUN 地址）。
    ///   - blockingPool: `getaddrinfo` 回退使用的线程池；为 nil 时没有回退。
    public init(provider: @escaping @Sendable () -> [IPAddress], excluded: [CIDR], blockingPool: NIOThreadPool?) {
        self.provider = provider
        self.excluded = excluded
        self.blockingPool = blockingPool
    }

    /// 重新读取服务器列表（网络变化时）。
    public func refresh() {
        servers.withLockedValue { $0 = nil }
    }

    /// 当前使用的服务器（排除后）。
    public var currentServers: [IPAddress] {
        resolvedServers().compactMap { $0.address.ipAddress.flatMap(IPAddress.init) }
    }

    private func resolvedServers() -> [UDPDNSUpstream] {
        servers.withLockedValue { cached in
            if let cached { return cached }
            let list = provider().filter { address in !excluded.contains { $0.contains(address) } }.compactMap {
                try? SocketAddress(ipAddress: $0.description, port: 53)
            }.map { UDPDNSUpstream(address: $0, isSystem: true) }
            cached = list
            return list
        }
    }

    public func send(_ query: [UInt8], on eventLoop: any EventLoop) -> EventLoopFuture<[UInt8]> {
        let upstreams = resolvedServers()
        if upstreams.isEmpty {
            return fallback(query, on: eventLoop)
        }
        // 多个系统服务器之间同样并发、取首个 NOERROR / NXDOMAIN。
        let promise = eventLoop.makePromise(of: [UInt8].self)
        let state = NIOLockedValueBox<(pending: Int, fallback: [UInt8]?, error: (any Error)?)>(
            (upstreams.count, nil, nil))
        for upstream in upstreams {
            upstream.send(query, on: eventLoop).whenComplete { result in
                let decision: Result<[UInt8], any Error>? = state.withLockedValue { state in
                    state.pending -= 1
                    switch result {
                    case .success(let bytes):
                        let code = bytes.count > 3 ? bytes[3] & 0x0F : 2
                        if code == 0 || code == 3 { return .success(bytes) }
                        state.fallback = bytes
                    case .failure(let error):
                        state.error = error
                    }
                    guard state.pending == 0 else { return nil }
                    if let fallback = state.fallback { return .success(fallback) }
                    return .failure(state.error ?? DNSError(.dnsUpstreamUnreachable, "System DNS failed"))
                }
                if let decision {
                    promise.completeWith(decision)
                }
            }
        }
        return promise.futureResult
    }

    /// 没有系统服务器时，用 `getaddrinfo` 解析 A / AAAA 并合成应答；其它类型回复 SERVFAIL。
    private func fallback(_ query: [UInt8], on eventLoop: any EventLoop) -> EventLoopFuture<[UInt8]> {
        guard let message = try? DNSMessage.decode(query), let question = message.questions.first else {
            return eventLoop.makeFailedFuture(DNSError(.dnsMalformedResponse, "Undecodable query"))
        }
        guard let blockingPool, question.type == .a || question.type == .aaaa else {
            return eventLoop.makeSucceededFuture(DNSMessage.response(to: message, code: .serverFailure).encode())
        }
        let host = question.name.text
        let family = question.type == .a ? AF_INET : AF_INET6
        return blockingPool.runIfActive(eventLoop: eventLoop) {
            try Getaddrinfo.lookup(host: host, family: family)
        }.map { addresses in
            let answers = addresses.map { address -> DNSResourceRecord in
                switch address {
                case .v4(let v4): return DNSResourceRecord(name: question.name, type: .a, ttl: 60, data: .a(v4))
                case .v6(let v6): return DNSResourceRecord(name: question.name, type: .aaaa, ttl: 60, data: .aaaa(v6))
                }
            }
            return DNSMessage.response(to: message, answers: answers).encode()
        }.flatMapErrorThrowing { _ in
            DNSMessage.response(to: message, code: .nameError).encode()
        }
    }
}

/// 阻塞的 `getaddrinfo`，只能在线程池中调用。
enum Getaddrinfo {
    struct Failure: Error {
        let code: Int32
    }

    static func lookup(host: String, family: Int32) throws -> [IPAddress] {
        var hints = addrinfo()
        hints.ai_family = family
        #if canImport(Glibc)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
            hints.ai_socktype = SOCK_STREAM
        #endif
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { throw Failure(code: status) }
        defer { freeaddrinfo(first) }
        var addresses: [IPAddress] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let address = info.pointee.ai_addr {
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    let v4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
                    addresses.append(.v4(IPv4Address(UInt32(bigEndian: v4))))
                case AF_INET6:
                    let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                    }
                    if let v6 = IPv6Address(bytes: bytes) {
                        addresses.append(.v6(v6))
                    }
                default:
                    break
                }
            }
            cursor = info.pointee.ai_next
        }
        var seen = Set<IPAddress>()
        return addresses.filter { seen.insert($0).inserted }
    }
}

/// `/etc/resolv.conf` 中的 `nameserver` 行（`aether-cli` 在 Linux / macOS 上作为系统 DNS 来源）。
public enum ResolvConf {
    public static func nameservers(from text: String) -> [IPAddress] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> IPAddress? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "nameserver" else { return nil }
            // 去掉 IPv6 的区域 ID（fe80::1%eth0）。
            let address = fields[1].split(separator: "%").first.map(String.init) ?? ""
            return IPAddress(address)
        }
    }
}
