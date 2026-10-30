import AetherFoundation
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// 一个 DNS 上游（docs/07 §4）。实现都只在调用方给定的 EventLoop 上完成 I/O。
public protocol DNSUpstream: AnyObject, Sendable {
    /// 展示名，如 `192.0.2.53:53`、`system`。
    var name: String { get }
    /// 是否为 `system` 上游（网络变化时其缓存失效）。
    var isSystem: Bool { get }
    /// 发送查询（ID 已由调用方设好），返回原始应答。失败以 `DNSError` 结束。
    func send(_ query: [UInt8], on eventLoop: any EventLoop) -> EventLoopFuture<[UInt8]>
}

/// 上游写法（`dns-server`、`encrypted-dns-server`、`[Host]` 的 `server:`）。
public enum DNSUpstreamSpec: Hashable, Sendable {
    case system
    case udp(host: String, port: Int)
    /// DoH（M3）。
    case https(String)
    /// DoT（M3）。
    case tls(String)
    /// DoQ（M7）。
    case quic(String)

    /// 解析：`system`、`IPv4[:端口]`、`[IPv6]:端口`、裸 IPv6、`https://…`、`tls://…`、`quic://…`。无法识别时为 nil。
    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower == "system" {
            self = .system
        } else if lower.hasPrefix("https://") {
            self = .https(trimmed)
        } else if lower.hasPrefix("tls://") {
            self = .tls(trimmed)
        } else if lower.hasPrefix("quic://") {
            self = .quic(trimmed)
        } else if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            guard IPAddress(host) != nil else { return nil }
            let rest = trimmed[trimmed.index(after: close)...]
            if rest.isEmpty {
                self = .udp(host: host, port: 53)
            } else {
                guard rest.hasPrefix(":"), let port = Int(rest.dropFirst()), (1...65535).contains(port) else {
                    return nil
                }
                self = .udp(host: host, port: port)
            }
        } else if IPAddress(trimmed) != nil {
            self = .udp(host: trimmed, port: 53)
        } else {
            let parts = trimmed.split(separator: ":")
            guard parts.count == 2, IPAddress(parts[0]) != nil, let port = Int(parts[1]), (1...65535).contains(port)
            else { return nil }
            self = .udp(host: String(parts[0]), port: port)
        }
    }

    /// M2 是否已实现。
    public var isSupported: Bool {
        switch self {
        case .system, .udp: return true
        case .https, .tls, .quic: return false
        }
    }
}

/// 上游的近期表现（DNS 诊断页，docs/07 §4.2）：最近 20 次成功耗时与累计失败次数。
public struct DNSUpstreamStatistics: Sendable, Hashable {
    public static let historyLimit = 20

    public var name: String
    /// 最近的成功耗时（毫秒），最新在后，最多 20 个。
    public var recentDurationsMs: [Int] = []
    public var failures = 0
    public var lastError: String?

    public init(name: String) {
        self.name = name
    }

    mutating func recordSuccess(_ duration: TimeAmount) {
        recentDurationsMs.append(Int(duration.nanoseconds / 1_000_000))
        if recentDurationsMs.count > Self.historyLimit {
            recentDurationsMs.removeFirst(recentDurationsMs.count - Self.historyLimit)
        }
    }

    mutating func recordFailure(_ error: any Error) {
        failures += 1
        lastError = (error as? DNSError)?.code.rawValue ?? String(describing: error)
    }
}

// MARK: - UDP / TCP

/// 普通 DNS 上游（RFC 1035）：每次查询使用新的 UDP socket（随机源端口），超时 2 秒、重试 1 次；
/// 响应带 TC 位时改用 TCP 向同一服务器重查。
public final class UDPDNSUpstream: DNSUpstream {
    public let address: SocketAddress
    public let name: String
    public let isSystem: Bool
    public let attemptTimeout: TimeAmount
    public let retries: Int

    public init(
        address: SocketAddress, isSystem: Bool = false, attemptTimeout: TimeAmount = .seconds(2), retries: Int = 1
    ) {
        self.address = address
        self.isSystem = isSystem
        self.attemptTimeout = attemptTimeout
        self.retries = retries
        if let ip = address.ipAddress, let port = address.port {
            name = address.protocol == .inet6 ? "[\(ip)]:\(port)" : "\(ip):\(port)"
        } else {
            name = "\(address)"
        }
    }

    public func send(_ query: [UInt8], on eventLoop: any EventLoop) -> EventLoopFuture<[UInt8]> {
        attempt(query, on: eventLoop, remaining: retries).flatMap { response in
            if response.count > 2, response[2] & 0x02 != 0 {
                return DNSTCPClient.query(query, server: self.address, timeout: self.attemptTimeout, on: eventLoop)
            }
            return eventLoop.makeSucceededFuture(response)
        }
    }

    private func attempt(_ query: [UInt8], on eventLoop: any EventLoop, remaining: Int) -> EventLoopFuture<[UInt8]> {
        DNSUDPClient.query(query, server: address, timeout: attemptTimeout, on: eventLoop).flatMapError { error in
            if remaining > 0, (error as? DNSError)?.code == .dnsTimeout {
                return self.attempt(query, on: eventLoop, remaining: remaining - 1)
            }
            return eventLoop.makeFailedFuture(error)
        }
    }
}

enum DNSUDPClient {
    static func query(_ query: [UInt8], server: SocketAddress, timeout: TimeAmount, on eventLoop: any EventLoop)
        -> EventLoopFuture<[UInt8]>
    {
        guard let id = DNSWire.id(of: query) else {
            return eventLoop.makeFailedFuture(DNSError(.dnsMalformedResponse, "Query too short"))
        }
        let promise = eventLoop.makePromise(of: [UInt8].self)
        let bindHost = server.protocol == .inet6 ? "::" : "0.0.0.0"
        DatagramBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(
                        DatagramResponseHandler(server: server, id: id, promise: promise))
                }
            }
            .bind(host: bindHost, port: 0)
            .whenComplete { result in
                switch result {
                case .failure(let error):
                    promise.fail(DNSError(.dnsUpstreamUnreachable, "\(error)"))
                case .success(let channel):
                    let timer = eventLoop.scheduleTask(in: timeout) {
                        promise.fail(DNSError(.dnsTimeout, "No reply from \(server) within \(timeout)"))
                    }
                    promise.futureResult.whenComplete { _ in
                        timer.cancel()
                        channel.close(promise: nil)
                    }
                    let envelope = AddressedEnvelope(remoteAddress: server, data: ByteBuffer(bytes: query))
                    channel.writeAndFlush(envelope).whenFailure { error in
                        promise.fail(DNSError(.dnsUpstreamUnreachable, "\(error)"))
                    }
                }
            }
        return promise.futureResult
    }
}

/// 只接受来自目标服务器、ID 匹配的第一个应答。
private final class DatagramResponseHandler: ChannelInboundHandler {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let server: SocketAddress
    private let id: UInt16
    private let promise: EventLoopPromise<[UInt8]>

    init(server: SocketAddress, id: UInt16, promise: EventLoopPromise<[UInt8]>) {
        self.server = server
        self.id = id
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        guard envelope.remoteAddress == server else { return }
        let bytes = Array(envelope.data.readableBytesView)
        guard DNSWire.id(of: bytes) == id, bytes.count >= DNSWire.headerLength else { return }
        promise.succeed(bytes)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise.fail(DNSError(.dnsUpstreamUnreachable, "\(error)"))
    }
}

@available(*, unavailable)
extension DatagramResponseHandler: Sendable {}

/// DNS over TCP（RFC 7766）：2 字节长度前缀；每次查询一个连接。
enum DNSTCPClient {
    static func query(_ query: [UInt8], server: SocketAddress, timeout: TimeAmount, on eventLoop: any EventLoop)
        -> EventLoopFuture<[UInt8]>
    {
        let promise = eventLoop.makePromise(of: [UInt8].self)
        ClientBootstrap(group: eventLoop)
            .connectTimeout(timeout)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(StreamResponseHandler(promise: promise))
                }
            }
            .connect(to: server)
            .whenComplete { result in
                switch result {
                case .failure(let error):
                    promise.fail(DNSError(.dnsUpstreamUnreachable, "\(error)"))
                case .success(let channel):
                    let timer = eventLoop.scheduleTask(in: timeout) {
                        promise.fail(DNSError(.dnsTimeout, "No TCP reply from \(server) within \(timeout)"))
                    }
                    promise.futureResult.whenComplete { _ in
                        timer.cancel()
                        channel.close(promise: nil)
                    }
                    var buffer = channel.allocator.buffer(capacity: query.count + 2)
                    buffer.writeInteger(UInt16(clamping: query.count))
                    buffer.writeBytes(query)
                    channel.writeAndFlush(buffer, promise: nil)
                }
            }
        return promise.futureResult
    }
}

/// 读取一个长度前缀帧。
private final class StreamResponseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<[UInt8]>
    private var buffer = ByteBuffer()

    init(promise: EventLoopPromise<[UInt8]>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        if let frame = DNSStreamFraming.nextFrame(from: &buffer) {
            promise.succeed(frame)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(DNSError(.dnsMalformedResponse, "Connection closed before a complete response"))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise.fail(DNSError(.dnsUpstreamUnreachable, "\(error)"))
        context.close(promise: nil)
    }
}

@available(*, unavailable)
extension StreamResponseHandler: Sendable {}

/// 2 字节长度前缀分帧（DNS over TCP / DoT）。
public enum DNSStreamFraming {
    /// 从缓冲中取出一个完整帧（消费掉它）；数据不足时返回 nil 且不消费。
    public static func nextFrame(from buffer: inout ByteBuffer) -> [UInt8]? {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self),
            buffer.readableBytes >= 2 + Int(length)
        else { return nil }
        buffer.moveReaderIndex(forwardBy: 2)
        return buffer.readBytes(length: Int(length))
    }

    /// 加上长度前缀。
    public static func frame(_ message: [UInt8], allocator: ByteBufferAllocator) -> ByteBuffer {
        var buffer = allocator.buffer(capacity: message.count + 2)
        buffer.writeInteger(UInt16(clamping: message.count))
        buffer.writeBytes(message)
        return buffer
    }
}
