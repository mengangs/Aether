import AetherFoundation
import NIOCore
import NIOPosix

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// NAT64 支持（docs/06 §6 第 8 步）：当前网络不支持 IPv4（纯 IPv6 + NAT64）时，IPv4 目标先合成 IPv6 地址再连接。
/// 🔬 合成依赖系统 `getaddrinfo` 对 IPv4 字面量的处理，需要真机验证（13 §6 V06）。
public struct NAT64Support: Sendable {
    /// 当前网络是否有可用的 IPv4（由路径监控提供）。
    public var hasIPv4: @Sendable () -> Bool
    /// 把 IPv4 地址合成为 IPv6；在阻塞线程池中执行。返回 nil 表示无法合成（按原地址连接）。
    public var synthesize: @Sendable (IPv4Address, any EventLoop) -> EventLoopFuture<IPv6Address?>

    public init(
        hasIPv4: @escaping @Sendable () -> Bool,
        synthesize: @escaping @Sendable (IPv4Address, any EventLoop) -> EventLoopFuture<IPv6Address?>
    ) {
        self.hasIPv4 = hasIPv4
        self.synthesize = synthesize
    }

    /// 用线程池中的 `getaddrinfo(AI_DEFAULT)` 合成：在 NAT64 网络上，系统对 IPv4 字面量返回合成的 IPv6 地址。
    public static func systemSynthesizer(pool: NIOThreadPool, hasIPv4: @escaping @Sendable () -> Bool)
        -> NAT64Support
    {
        NAT64Support(hasIPv4: hasIPv4) { address, eventLoop in
            pool.runIfActive(eventLoop: eventLoop) { () -> IPv6Address? in
                var hints = addrinfo()
                hints.ai_family = AF_INET6
                #if canImport(Darwin)
                    hints.ai_flags = AI_DEFAULT
                    hints.ai_socktype = SOCK_STREAM
                #else
                    hints.ai_flags = AI_V4MAPPED | AI_ADDRCONFIG
                    hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
                #endif
                var result: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(address.description, nil, &hints, &result) == 0, let first = result else {
                    return nil
                }
                defer { freeaddrinfo(first) }
                guard let raw = first.pointee.ai_addr, Int32(raw.pointee.sa_family) == AF_INET6 else { return nil }
                let bytes = raw.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                }
                guard let v6 = IPv6Address(bytes: bytes), v6.mappedIPv4 == nil else { return nil }
                return v6
            }
        }
    }
}

/// 建立到 `host:port` 的 TCP 连接（DIRECT 目标或代理节点服务器）。域名经 `ServerAddressResolver` 解析，
/// 以 NIO 的 Happy Eyeballs（RFC 8305）在多个地址间竞速；IP 目标直接连接。
public enum TCPDialer {
    public static func connect(
        host: String, port: UInt16, preference: AddressFamilyPreference = .dual, resolver: any ServerAddressResolver,
        nat64: NAT64Support?, eventLoop: any EventLoop, connectTimeout: TimeAmount = ChannelTuning.connectTimeout
    ) -> EventLoopFuture<any Channel> {
        let future: EventLoopFuture<any Channel>
        if let address = IPAddress(host) {
            future = connectIP(
                address.unmappedIPv4, port: port, nat64: nat64, eventLoop: eventLoop, connectTimeout: connectTimeout)
        } else {
            let adapter = HappyEyeballsResolver(
                resolver: resolver, preference: preference, nat64: nat64, eventLoop: eventLoop)
            future = ChannelTuning.configure(ClientBootstrap(group: eventLoop)).connectTimeout(connectTimeout)
                .resolver(adapter).connect(host: host, port: Int(port)).map { $0 as any Channel }
        }
        return future.flatMapErrorThrowing { error in
            throw NetworkErrorMapping.map(error)
        }
    }

    private static func connectIP(
        _ address: IPAddress, port: UInt16, nat64: NAT64Support?, eventLoop: any EventLoop, connectTimeout: TimeAmount
    ) -> EventLoopFuture<any Channel> {
        if case .v4(let v4) = address, let nat64, !nat64.hasIPv4() {
            return nat64.synthesize(v4, eventLoop).flatMap { synthesized in
                let target: IPAddress = synthesized.map { .v6($0) } ?? address
                return connectSocket(target, port: port, eventLoop: eventLoop, connectTimeout: connectTimeout)
            }
        }
        return connectSocket(address, port: port, eventLoop: eventLoop, connectTimeout: connectTimeout)
    }

    private static func connectSocket(
        _ address: IPAddress, port: UInt16, eventLoop: any EventLoop, connectTimeout: TimeAmount
    ) -> EventLoopFuture<any Channel> {
        do {
            let socketAddress = try SocketAddress(ipAddress: address.description, port: Int(port))
            return ChannelTuning.configure(ClientBootstrap(group: eventLoop)).connectTimeout(connectTimeout)
                .connect(to: socketAddress).map { $0 as any Channel }
        } catch {
            return eventLoop.makeFailedFuture(NetworkError(.netUnreachable, "Invalid address \(address)"))
        }
    }
}

/// 把 `ServerAddressResolver` 适配为 NIO 的 `Resolver`，供 Happy Eyeballs 使用。
/// - `v4-only` / `v6-only`：另一族返回空；
/// - `prefer-v4` / `prefer-v6`：非首选族的查询等首选族完成后才返回，使首选族先参与竞速；
/// - NAT64：网络没有 IPv4 时，A 记录结果经合成器转为 IPv6。
final class HappyEyeballsResolver: Resolver, @unchecked Sendable {
    private let resolver: any ServerAddressResolver
    private let preference: AddressFamilyPreference
    private let nat64: NAT64Support?
    private let eventLoop: any EventLoop
    /// 首选族的查询完成（只在 prefer-v4 / prefer-v6 时使用）。只在 `eventLoop` 上完成，且保证完成一次：
    /// 首选族查询结束或查询被取消时。
    private let preferredDone: EventLoopPromise<Void>?
    private var preferredCompleted = false

    init(
        resolver: any ServerAddressResolver, preference: AddressFamilyPreference, nat64: NAT64Support?,
        eventLoop: any EventLoop
    ) {
        self.resolver = resolver
        self.preference = preference
        self.nat64 = nat64
        self.eventLoop = eventLoop
        switch preference {
        case .preferV4, .preferV6: preferredDone = eventLoop.makePromise()
        default: preferredDone = nil
        }
    }

    private func completePreferred() {
        eventLoop.execute {
            guard !self.preferredCompleted else { return }
            self.preferredCompleted = true
            self.preferredDone?.succeed(())
        }
    }

    func initiateAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        guard preference != .v6Only else { return eventLoop.makeSucceededFuture([]) }
        let query = resolver.resolve(host, family: .v4, on: eventLoop).flatMap {
            addresses -> EventLoopFuture<[SocketAddress]> in
            if let nat64 = self.nat64, !nat64.hasIPv4() {
                let synthesized = addresses.compactMap { address -> EventLoopFuture<IPAddress?>? in
                    guard case .v4(let v4) = address else { return nil }
                    return nat64.synthesize(v4, self.eventLoop).map { $0.map { .v6($0) } }
                }
                return EventLoopFuture.whenAllSucceed(synthesized, on: self.eventLoop).map {
                    Self.socketAddresses($0.compactMap { $0 }, port: port)
                }
            }
            return self.eventLoop.makeSucceededFuture(Self.socketAddresses(addresses, port: port))
        }
        return ordered(query, isPreferred: preference == .preferV4)
    }

    func initiateAAAAQuery(host: String, port: Int) -> EventLoopFuture<[SocketAddress]> {
        guard preference != .v4Only else { return eventLoop.makeSucceededFuture([]) }
        let query = resolver.resolve(host, family: .v6, on: eventLoop).map { Self.socketAddresses($0, port: port) }
        return ordered(query, isPreferred: preference == .preferV6)
    }

    func cancelQueries() {
        completePreferred()
    }

    private func ordered(_ query: EventLoopFuture<[SocketAddress]>, isPreferred: Bool) -> EventLoopFuture<
        [SocketAddress]
    > {
        guard let preferredDone else { return query }
        if isPreferred {
            query.whenComplete { _ in self.completePreferred() }
            return query
        }
        return query.flatMap { result in preferredDone.futureResult.map { result } }
    }

    private static func socketAddresses(_ addresses: [IPAddress], port: Int) -> [SocketAddress] {
        addresses.compactMap { try? SocketAddress(ipAddress: $0.description, port: port) }
    }
}

/// 把 NIO / 系统错误映射为 `NET` 错误码（docs/06 §15）。
public enum NetworkErrorMapping {
    public static func map(_ error: any Error) -> any AetherErrorProtocol {
        if let aether = error as? any AetherErrorProtocol {
            return aether
        }
        if let connection = error as? NIOConnectionError {
            if let dnsError = connection.dnsAError ?? connection.dnsAAAAError {
                return (dnsError as? any AetherErrorProtocol)
                    ?? NetworkError(.netResolutionFailed, "Resolving \(connection.host) failed")
            }
            if connection.connectionErrors.isEmpty {
                return NetworkError(.netResolutionFailed, "\(connection.host) has no usable address")
            }
            return map(connection.connectionErrors.map(\.error).last ?? error)
        }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .connectTimeout: return NetworkError(.netConnectTimeout, "Connect timed out")
            case .connectPending, .eof, .alreadyClosed, .ioOnClosedChannel, .outputClosed, .inputClosed:
                return NetworkError(.netConnectionReset, "\(channelError)")
            default: return NetworkError(.netConnectionRefused, "\(channelError)")
            }
        }
        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNREFUSED: return NetworkError(.netConnectionRefused, "Connection refused")
            case ETIMEDOUT: return NetworkError(.netConnectTimeout, "Connect timed out")
            case ENETUNREACH, EHOSTUNREACH, EADDRNOTAVAIL, EAFNOSUPPORT:
                return NetworkError(.netUnreachable, "Network unreachable")
            case ECONNRESET, EPIPE: return NetworkError(.netConnectionReset, "Connection reset")
            default: return NetworkError(.netConnectionRefused, "errno \(ioError.errnoCode)")
            }
        }
        return NetworkError(.netConnectionRefused, String(describing: error))
    }
}
