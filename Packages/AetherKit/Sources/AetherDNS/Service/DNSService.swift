import AetherFoundation
import NIOCore
import NIOPosix

/// DNS 配置（由引擎从 `[General]` 与 `[Host]` 转换而来）。
public struct DNSConfiguration: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        case fakeIP = "fake-ip"
        case realIP = "real-ip"
    }

    public var mode = Mode.fakeIP
    public var fakeIPRange = CIDR(ipv4: IPv4Address(198, 18, 0, 0), prefixLength: 15)
    public var ipv6 = false
    /// `always-real-ip`；nil 表示使用内置表（docs/07 §3.3）。
    public var alwaysRealIP: [String]?
    public var hosts: [HostEntry] = []
    /// `dns-server`。
    public var servers = ["system"]
    /// `encrypted-dns-server`（DoH / DoT 在 M3-11 实现；M2 中忽略并退回 `dns-server`）。
    public var encryptedServers: [String] = []

    public init() {}
}

/// `resolve` 的用途（docs/07 §2.2）。
public enum ResolutionPurpose: String, Sendable, Equatable {
    /// 规则需要 IP。
    case routing
    /// DIRECT 连接。
    case direct
    /// 代理节点或加密 DNS 服务器的地址：只用 `dns-server` 组，避免加密 DNS 自举循环。
    case server
}

/// DNS 门面（docs/07）：应答设备上其它 App 的查询（`answer`），为引擎解析域名（`resolve`）。
///
/// 绑定到数据面 EventLoop：除 `init` 外的所有方法都必须在该 EventLoop 上调用。
public final class DNSService: @unchecked Sendable {
    /// 同时进行的上游查询上限（docs/06 §13）；超出时应答方回复 SERVFAIL，解析方以 `DNS-004` 失败。
    public static let maxConcurrentQueries = 256
    /// `[Host]` 静态地址与别名应答的 TTL。
    static let hostTTL: UInt32 = 60
    /// Fake IP 应答的 TTL（docs/07 §3.1）。
    static let fakeTTL: UInt32 = 1
    /// 别名的最大展开深度。
    static let maxAliasDepth = 8

    public struct Environment: Sendable {
        public var eventLoop: any EventLoop
        /// `getaddrinfo` 回退使用的线程池。
        public var blockingPool: NIOThreadPool?
        /// 系统 DNS 服务器（docs/07 §4.1）。
        public var systemServers: @Sendable () -> [IPAddress]
        public var logger: Logger
        /// 上游查询的事务 ID（测试可注入固定序列）。
        public var transactionID: @Sendable () -> UInt16
        /// 按写法构造上游；为 nil 时使用真实的 UDP / system 上游（测试注入假上游）。
        public var makeUpstream: (@Sendable (DNSUpstreamSpec) -> (any DNSUpstream)?)?

        public init(
            eventLoop: any EventLoop,
            blockingPool: NIOThreadPool? = nil,
            systemServers: @escaping @Sendable () -> [IPAddress] = { [] },
            logger: Logger = Logger(label: "AetherDNS"),
            transactionID: @escaping @Sendable () -> UInt16 = { UInt16.random(in: .min ... .max) },
            makeUpstream: (@Sendable (DNSUpstreamSpec) -> (any DNSUpstream)?)? = nil
        ) {
            self.eventLoop = eventLoop
            self.blockingPool = blockingPool
            self.systemServers = systemServers
            self.logger = logger
            self.transactionID = transactionID
            self.makeUpstream = makeUpstream
        }
    }

    /// 应答的传输方式：UDP 受长度上限约束，TCP 不受。
    public enum Transport: Sendable {
        case udp
        case tcp
    }

    public let eventLoop: any EventLoop
    private let environment: Environment
    public private(set) var configuration: DNSConfiguration
    public private(set) var fakeIPs: FakeIPPool
    private var hosts: HostTable
    private var realIPExceptions: RealIPExceptions
    private var cache = DNSCache()
    private var reverse = ReverseTable()
    private var plainGroup: DNSUpstreamGroup
    private var encryptedGroup: DNSUpstreamGroup?
    private var hostGroups: [String: DNSUpstreamGroup] = [:]
    private var systemUpstreams: [SystemDNSUpstream] = []
    private var inflight: [DNSCacheKey: EventLoopFuture<DNSUpstreamAnswer>] = [:]
    private var activeQueries = 0
    private var loggedRecycling = false

    public init(configuration: DNSConfiguration, environment: Environment) {
        eventLoop = environment.eventLoop
        self.environment = environment
        self.configuration = configuration
        fakeIPs = FakeIPPool(range: configuration.fakeIPRange)
        hosts = HostTable(entries: configuration.hosts)
        realIPExceptions = RealIPExceptions(patterns: configuration.alwaysRealIP)
        plainGroup = DNSUpstreamGroup(identifier: "plain", upstreams: [], eventLoop: environment.eventLoop)
        rebuildGroups()
    }

    /// 重载：替换 Host 表、例外表与上游组；缓存、反查表保持不变，Fake IP 段变化时才重建地址池（docs/06 §2.4）。
    public func update(configuration new: DNSConfiguration) {
        eventLoop.preconditionInEventLoop()
        let rangeChanged = new.fakeIPRange != configuration.fakeIPRange
        configuration = new
        if rangeChanged {
            fakeIPs = FakeIPPool(range: new.fakeIPRange)
        }
        hosts = HostTable(entries: new.hosts)
        realIPExceptions = RealIPExceptions(patterns: new.alwaysRealIP)
        rebuildGroups()
    }

    private func rebuildGroups() {
        systemUpstreams = []
        hostGroups = [:]
        plainGroup = makeGroup(identifier: "plain", specs: configuration.servers)
        encryptedGroup = nil
        if !configuration.encryptedServers.isEmpty {
            let group = makeGroup(identifier: "encrypted", specs: configuration.encryptedServers)
            if group.upstreams.isEmpty {
                environment.logger.notice(
                    "No encrypted DNS upstream is available; using dns-server",
                    metadata: ["count": "\(configuration.encryptedServers.count)"])
            } else {
                encryptedGroup = group
            }
        }
    }

    private func makeGroup(identifier: String, specs: [String]) -> DNSUpstreamGroup {
        let upstreams = specs.compactMap(DNSUpstreamSpec.init).compactMap(makeUpstream)
        return DNSUpstreamGroup(identifier: identifier, upstreams: upstreams, eventLoop: eventLoop)
    }

    /// 先用注入的工厂（引擎创建 DoH / DoT，测试替换上游），工厂返回 nil 时用内置实现（system、UDP）。
    private func makeUpstream(_ spec: DNSUpstreamSpec) -> (any DNSUpstream)? {
        if let factory = environment.makeUpstream, let made = factory(spec) {
            return made
        }
        switch spec {
        case .system:
            let excluded = [
                configuration.fakeIPRange, CIDR(ipv4: IPv4Address(198, 18, 0, 0), prefixLength: 15),
            ]
            let upstream = SystemDNSUpstream(
                provider: environment.systemServers, excluded: excluded, blockingPool: environment.blockingPool)
            systemUpstreams.append(upstream)
            return upstream
        case .udp(let host, let port):
            guard let address = try? SocketAddress(ipAddress: host, port: port) else { return nil }
            return UDPDNSUpstream(address: address)
        case .https, .tls, .quic:
            // DoH / DoT 由引擎注入的工厂创建；DoQ 在 M7。
            environment.logger.notice("DNS upstream type not available here", metadata: ["upstream": "\(spec)"])
            return nil
        }
    }

    private func group(forHostUpstream text: String) -> DNSUpstreamGroup {
        if let existing = hostGroups[text] {
            return existing
        }
        let group = makeGroup(identifier: "host:\(text)", specs: [text])
        hostGroups[text] = group
        return group
    }

    // MARK: - 应答方（docs/07 §2.1）

    /// 应答一个查询报文。无法识别为 DNS 报文（不足 12 字节）时返回 nil（丢弃）。
    public func answer(_ query: [UInt8], transport: Transport) -> EventLoopFuture<[UInt8]?> {
        eventLoop.preconditionInEventLoop()
        guard query.count >= DNSWire.headerLength, let id = DNSWire.id(of: query) else {
            return eventLoop.makeSucceededFuture(nil)
        }
        guard let message = try? DNSMessage.decode(query), !message.header.isResponse else {
            var header = DNSHeader(id: id, isResponse: true, recursionAvailable: true, responseCode: .formatError)
            header.recursionDesired = query.count > 2 && query[2] & 0x01 != 0
            return eventLoop.makeSucceededFuture(DNSMessage(header: header).encode())
        }
        let limit = transport == .udp ? DNSWire.udpLimit(for: message) : Int(UInt16.max)
        guard message.questions.count == 1, let question = message.questions.first else {
            return eventLoop.makeSucceededFuture(DNSMessage.response(to: message, code: .formatError).encode())
        }
        let domain = question.name.normalized
        let finish: @Sendable (DNSMessage) -> [UInt8]? = {
            DNSWire.truncateIfNeeded($0.encode(), query: message, limit: limit)
        }

        // 1. [Host]
        let hostValue = hosts.lookup(domain)
        if question.type == .a || question.type == .aaaa {
            switch hostValue {
            case .addresses(let addresses):
                return eventLoop.makeSucceededFuture(
                    finish(Self.addressResponse(to: message, addresses: addresses, ttl: Self.hostTTL)))
            case .alias(let target):
                return resolve(target, type: question.type, purpose: .direct).map { addresses in
                    finish(Self.addressResponse(to: message, addresses: addresses, ttl: Self.hostTTL))
                }.recover { error in
                    let code: DNSResponseCode =
                        (error as? DNSError)?.code == .dnsNameError ? .nameError : .serverFailure
                    return finish(DNSMessage.response(to: message, code: code))
                }
            case .upstream, nil:
                break
            }
        }
        let fake = configuration.mode == .fakeIP
        // 2. Fake IP
        if fake, question.type == .a, question.dnsClass == .internet, !realIPExceptions.contains(domain) {
            let address = fakeAddress(for: domain)
            let record = DNSResourceRecord(name: question.name, type: .a, ttl: Self.fakeTTL, data: .a(address))
            return eventLoop.makeSucceededFuture(finish(DNSMessage.response(to: message, answers: [record])))
        }
        // 3. ipv6 = false 时 AAAA 返回空答案
        if question.type == .aaaa, !configuration.ipv6 {
            return eventLoop.makeSucceededFuture(finish(DNSMessage.response(to: message)))
        }
        // 4. Fake IP 模式下 HTTPS / SVCB 返回空答案
        if fake, question.type == .https || question.type == .svcb {
            return eventLoop.makeSucceededFuture(finish(DNSMessage.response(to: message)))
        }
        // 5. Fake IP 段的 PTR
        if question.type == .ptr, let address = Self.reverseLookupAddress(domain), fakeIPs.contains(address) {
            guard let mapped = fakeIPs.domain(for: address), let target = DNSName(mapped) else {
                return eventLoop.makeSucceededFuture(finish(DNSMessage.response(to: message, code: .nameError)))
            }
            let record = DNSResourceRecord(name: question.name, type: .ptr, ttl: Self.fakeTTL, data: .ptr(target))
            return eventLoop.makeSucceededFuture(finish(DNSMessage.response(to: message, answers: [record])))
        }
        // 6. 缓存与上游
        let group: DNSUpstreamGroup
        if case .upstream(let text) = hostValue {
            group = self.group(forHostUpstream: text)
        } else {
            group = encryptedGroup ?? plainGroup
        }
        let key = DNSCacheKey(name: domain, type: question.type, dnsClass: question.dnsClass, group: group.identifier)
        return lookupUpstream(key: key, question: question, group: group).map { answer, storedAt in
            var response = answer.response
            DNSWire.setID(id, in: &response)
            DNSWire.copyQuestionName(from: query, into: &response)
            if let storedAt {
                let elapsed = (self.eventLoop.now - storedAt).nanoseconds / 1_000_000_000
                DNSWire.ageTTLs(
                    in: &response, fields: answer.scanned.ttlFields, elapsedSeconds: UInt32(clamping: elapsed))
            }
            return DNSWire.truncateIfNeeded(response, query: message, limit: limit)
        }.recover { _ in
            finish(DNSMessage.response(to: message, code: .serverFailure))
        }
    }

    private func fakeAddress(for domain: String) -> IPv4Address {
        let address = fakeIPs.address(for: domain)
        if fakeIPs.didStartRecycling, !loggedRecycling {
            loggedRecycling = true
            environment.logger.warning(
                "Fake IP pool exhausted; recycling least recently used mappings",
                metadata: ["code": "\(AetherErrorCode.dnsFakeIPRecycling)", "capacity": "\(fakeIPs.capacity)"])
        }
        return address
    }

    static func addressResponse(to query: DNSMessage, addresses: [IPAddress], ttl: UInt32) -> DNSMessage {
        guard let question = query.questions.first else { return DNSMessage.response(to: query) }
        let answers = addresses.compactMap { address -> DNSResourceRecord? in
            switch (question.type, address.unmappedIPv4) {
            case (.a, .v4(let v4)): return DNSResourceRecord(name: question.name, type: .a, ttl: ttl, data: .a(v4))
            case (.aaaa, .v6(let v6)):
                return DNSResourceRecord(name: question.name, type: .aaaa, ttl: ttl, data: .aaaa(v6))
            default: return nil
            }
        }
        return DNSMessage.response(to: query, answers: answers)
    }

    /// `d.c.b.a.in-addr.arpa` → `a.b.c.d`。
    static func reverseLookupAddress(_ name: String) -> IPAddress? {
        guard name.hasSuffix(".in-addr.arpa") else { return nil }
        let labels = name.dropLast(".in-addr.arpa".count).split(separator: ".")
        guard labels.count == 4 else { return nil }
        return IPAddress(labels.reversed().joined(separator: "."))
    }

    // MARK: - 解析方（docs/07 §2.2）

    /// 解析域名的一种地址记录（A 或 AAAA），从不返回 Fake IP。NXDOMAIN → `DNS-003`，SERVFAIL 等 → `DNS-002`；
    /// NOERROR 但没有该类型的记录时返回空数组。
    public func resolve(_ host: String, type: DNSRecordType, purpose: ResolutionPurpose) -> EventLoopFuture<
        [IPAddress]
    > {
        eventLoop.preconditionInEventLoop()
        return resolve(host.lowercased(), type: type, purpose: purpose, depth: 0)
    }

    private func resolve(_ domain: String, type: DNSRecordType, purpose: ResolutionPurpose, depth: Int)
        -> EventLoopFuture<[IPAddress]>
    {
        if let literal = IPAddress(domain) {
            let matches = (type == .a) == literal.unmappedIPv4.isIPv4
            return eventLoop.makeSucceededFuture(matches ? [literal] : [])
        }
        var group = purpose == .server ? plainGroup : (encryptedGroup ?? plainGroup)
        switch hosts.lookup(domain) {
        case .addresses(let addresses):
            return eventLoop.makeSucceededFuture(
                addresses.filter { (type == .a) == $0.unmappedIPv4.isIPv4 })
        case .alias(let target):
            guard depth < Self.maxAliasDepth else {
                return eventLoop.makeFailedFuture(DNSError(.dnsServerFailure, "Host alias chain too deep"))
            }
            return resolve(target.lowercased(), type: type, purpose: purpose, depth: depth + 1)
        case .upstream(let text):
            group = self.group(forHostUpstream: text)
        case nil:
            break
        }
        guard let name = DNSName(domain) else {
            return eventLoop.makeFailedFuture(DNSError(.dnsNameError, "Invalid domain name"))
        }
        let question = DNSQuestion(name: name, type: type)
        let key = DNSCacheKey(name: domain, type: type, group: group.identifier)
        return lookupUpstream(key: key, question: question, group: group).flatMapThrowing { answer, _ in
            switch answer.responseCode {
            case .noError:
                return answer.scanned.addresses.filter { (type == .a) == $0.unmappedIPv4.isIPv4 }
            case .nameError:
                throw DNSError(.dnsNameError, "\(domain) does not exist")
            default:
                throw DNSError(.dnsServerFailure, "Upstream answered \(answer.responseCode)")
            }
        }
    }

    /// 同时解析 A 与 AAAA，IPv4 在前；两者都失败时以 A 的错误失败（规则匹配用）。
    public func resolveAll(_ host: String, purpose: ResolutionPurpose) -> EventLoopFuture<[IPAddress]> {
        eventLoop.preconditionInEventLoop()
        let v4 = resolve(host, type: .a, purpose: purpose)
        let v6 = resolve(host, type: .aaaa, purpose: purpose)
        let promise = eventLoop.makePromise(of: [IPAddress].self)
        v4.assumeIsolated().whenComplete { first in
            v6.assumeIsolated().whenComplete { second in
                switch (first, second) {
                case (.success(let a), .success(let b)): promise.succeed(a + b)
                case (.success(let a), .failure): promise.succeed(a)
                case (.failure, .success(let b)): promise.succeed(b)
                case (.failure(let error), .failure): promise.fail(error)
                }
            }
        }
        return promise.futureResult
    }

    /// 缓存 → 在途合并 → 上游组。返回应答与（命中缓存时的）写入时间。成功的应答写入缓存，A / AAAA 写入反查表。
    private func lookupUpstream(key: DNSCacheKey, question: DNSQuestion, group: DNSUpstreamGroup)
        -> EventLoopFuture<(DNSUpstreamAnswer, NIODeadline?)>
    {
        let now = eventLoop.now
        if let entry = cache.lookup(key, now: now) {
            return eventLoop.makeSucceededFuture((entry.answer, entry.storedAt))
        }
        if let pending = inflight[key] {
            return pending.map { ($0, nil) }
        }
        guard activeQueries < Self.maxConcurrentQueries else {
            return eventLoop.makeFailedFuture(DNSError(.dnsUpstreamUnreachable, "Too many concurrent DNS queries"))
        }
        var header = DNSHeader(id: environment.transactionID())
        header.recursionDesired = true
        let query = DNSMessage(
            header: header, questions: [question],
            additionals: [DNSEDNS(udpPayloadSize: DNSWire.ednsPayloadSize).record]
        ).encode()
        activeQueries += 1
        let future = group.query(query)
        inflight[key] = future
        future.assumeIsolated().whenComplete { result in
            self.activeQueries -= 1
            self.inflight[key] = nil
            if case .success(let answer) = result {
                self.cache.store(answer, for: key, now: self.eventLoop.now)
                let addresses = answer.scanned.addresses
                if !addresses.isEmpty {
                    self.reverse.record(addresses, domain: key.name)
                }
            }
        }
        return future.map { ($0, nil) }
    }

    // MARK: - 引擎查询

    /// 地址是否属于 Fake IP 段。
    public func isFakeIP(_ address: IPAddress) -> Bool {
        fakeIPs.contains(address)
    }

    /// Fake IP 反查（并标记为最近使用）。
    public func domain(forFakeIP address: IPAddress) -> String? {
        eventLoop.preconditionInEventLoop()
        return fakeIPs.domain(for: address)
    }

    /// 真实 IP 反查（docs/07 §6）。
    public func domain(forRealIP address: IPAddress) -> String? {
        eventLoop.preconditionInEventLoop()
        return reverse.domain(for: address)
    }

    // MARK: - 维护

    /// 网络环境变化：重新读取系统 DNS 服务器、清空来自 system 上游的缓存（docs/06 §11）。
    public func networkChanged() {
        eventLoop.preconditionInEventLoop()
        for upstream in systemUpstreams {
            upstream.refresh()
        }
        cache.removeSystemEntries()
    }

    /// 清空正向与否定缓存（不清 Fake IP 表）。
    public func flushCache() {
        eventLoop.preconditionInEventLoop()
        cache.removeAll()
    }

    /// 关闭各上游保持的连接（DoH / DoT；网络变化时，docs/06 §11）。
    public func resetUpstreams() {
        eventLoop.preconditionInEventLoop()
        let groups = [plainGroup] + (encryptedGroup.map { [$0] } ?? []) + Array(hostGroups.values)
        for upstream in groups.flatMap(\.upstreams) {
            upstream.reset()
        }
    }

    /// 内存压力 warning：清空正向缓存与反查表，保留 Fake IP 表（docs/02 §6）。
    public func releaseMemory() {
        eventLoop.preconditionInEventLoop()
        cache.removeAll()
        reverse.removeAll()
    }

    /// Fake IP 快照（`State/fakeip.bin`）。
    public func fakeIPSnapshot() -> [UInt8] {
        eventLoop.preconditionInEventLoop()
        return fakeIPs.serialize()
    }

    @discardableResult
    public func loadFakeIPSnapshot(_ bytes: [UInt8]) -> Bool {
        eventLoop.preconditionInEventLoop()
        return fakeIPs.load(bytes)
    }

    // MARK: - 观测（docs/07 §8）

    public struct CacheEntryInfo: Sendable, Hashable {
        public var name: String
        public var type: DNSRecordType
        public var responseCode: DNSResponseCode
        public var addresses: [IPAddress]
        public var remainingSeconds: Int64
        public var upstream: String
        public var durationMs: Int
    }

    public func cacheEntries(offset: Int = 0, limit: Int = 200) -> [CacheEntryInfo] {
        eventLoop.preconditionInEventLoop()
        let now = eventLoop.now
        return cache.entries(offset: offset, limit: limit).map { key, entry in
            CacheEntryInfo(
                name: key.name, type: key.type, responseCode: entry.answer.responseCode,
                addresses: entry.answer.scanned.addresses,
                remainingSeconds: max(0, (entry.expiresAt - now).nanoseconds / 1_000_000_000),
                upstream: entry.answer.upstream, durationMs: Int(entry.answer.duration.nanoseconds / 1_000_000))
        }
    }

    public var cacheCount: Int {
        eventLoop.preconditionInEventLoop()
        return cache.count
    }

    public func upstreamStatistics() -> [DNSUpstreamStatistics] {
        eventLoop.preconditionInEventLoop()
        return
            ([plainGroup] + (encryptedGroup.map { [$0] } ?? [])
            + hostGroups.values.sorted { $0.identifier < $1.identifier })
            .flatMap(\.upstreamStatistics)
    }

    /// 当前使用的系统 DNS 服务器（诊断页）。
    public var systemServers: [IPAddress] {
        systemUpstreams.first?.currentServers ?? []
    }
}
