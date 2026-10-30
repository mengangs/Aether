import AetherFoundation
import AetherOutbound
import AetherTestSupport
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

/// 经出站连接器访问回环源站与 UDP 服务的最小客户端（只为互通测试）。
struct InteropClient: Sendable {
    struct Timeout: Error {}

    struct Response: Sendable {
        var status: Int
        var bytes: Int
        var sha256: [UInt8]
        /// 收到了 `Content-Length` 声明的全部正文。
        var complete: Bool
        /// 正文的前 64 KiB。
        var prefix: [UInt8]
    }

    struct UDPResult: Sendable {
        var dnsAnswered: Bool
        var received: Int
        var reordered: Int
    }

    let group: any EventLoopGroup
    let originPort: UInt16

    static let loopback = IPAddress("127.0.0.1")!

    static func pattern(count: Int) -> [UInt8] {
        (0..<count).map { HTTPTestOrigin.byte(at: $0) }
    }

    static func digest(count: Int) -> [UInt8] {
        var hasher = SHA256()
        let block = pattern(count: 251 * 1024)
        var remaining = count
        while remaining > 0 {
            let take = min(remaining, block.count)
            hasher.update(data: block[..<take])
            remaining -= take
        }
        return Array(hasher.finalize())
    }

    static let largeDigest = digest(count: 64 * 1024 * 1024)

    /// 节点服务器都写成 IP，不需要解析。
    private struct NoResolver: ServerAddressResolver {
        func resolve(_ host: String, family: AddressFamily, on eventLoop: any EventLoop) -> EventLoopFuture<[IPAddress]>
        {
            eventLoop.makeSucceededFuture([])
        }
    }

    private func context(_ loop: any EventLoop) -> DialContext {
        DialContext(
            flowID: FlowID(rawValue: UInt64.random(in: 1...UInt64.max)), eventLoop: loop,
            deadline: .now() + .seconds(15), serverResolver: NoResolver(), logger: Logger(label: "interop"))
    }

    /// 经 `connector` 对源站发一个 `GET`。超过 `timeout` 抛出 `Timeout`。
    func get(_ connector: any OutboundConnector, path: String, timeout: TimeAmount = .seconds(15)) async throws
        -> Response
    {
        let loop = group.next()
        let channel = try await connector.connect(
            to: .ip(Self.loopback, port: originPort), context: context(loop)
        ).get()
        let promise = loop.makePromise(of: Response.self)
        let timer = loop.scheduleTask(in: timeout) {
            promise.fail(Timeout())
            channel.close(promise: nil)
        }
        defer { timer.cancel() }
        try await loop.submit {
            try channel.pipeline.syncOperations.addHandler(ResponseReader(promise: promise))
            try channel.syncOptions?.setOption(.autoRead, value: true)
            channel.read()
            let request = "GET \(path) HTTP/1.1\r\nHost: origin.example.com\r\nConnection: close\r\n\r\n"
            channel.writeAndFlush(ByteBuffer(string: request), promise: nil)
        }.get()
        let response = try await promise.futureResult.get()
        channel.close(promise: nil)
        return response
    }

    /// DNS 查询一次，再按 50 个一批发送 1000 个回显包，统计收到的个数与乱序次数。
    func udpChecks(_ connector: any OutboundConnector, servers: InteropUDPServers) async throws -> UDPResult {
        let loop = group.next()
        let association = try await connector.openUDP(context: context(loop)).get()
        let dnsTarget = Destination.ip(Self.loopback, port: servers.dnsPort)
        let echoTarget = Destination.ip(Self.loopback, port: servers.echoPort)
        let state = NIOLockedValueBox<(dns: Bool, sequence: [UInt32])>((false, []))
        try await loop.submit {
            association.onDatagram = { payload, source in
                if source == dnsTarget {
                    let answered = InteropUDPServers.isExpectedAnswer(payload)
                    state.withLockedValue { $0.dns = $0.dns || answered }
                } else if source == echoTarget,
                    let number = payload.getInteger(at: payload.readerIndex, as: UInt32.self)
                {
                    state.withLockedValue { $0.sequence.append(number) }
                }
            }
            association.send(InteropUDPServers.query(), to: dnsTarget)
        }.get()
        _ = await Poll.until(timeout: .seconds(5)) { state.withLockedValue { $0.dns } }
        for batch in 0..<20 {
            try await loop.submit {
                for index in 0..<50 {
                    var packet = ByteBuffer()
                    packet.writeInteger(UInt32(batch * 50 + index))
                    packet.writeRepeatingByte(0x61, count: 60)
                    association.send(packet, to: echoTarget)
                }
            }.get()
            _ = await Poll.until(timeout: .seconds(2)) {
                state.withLockedValue { $0.sequence.count } >= (batch + 1) * 50
            }
        }
        try await loop.submit { association.close() }.get()
        let (dns, sequence) = state.withLockedValue { ($0.dns, $0.sequence) }
        let reordered = zip(sequence, sequence.dropFirst()).filter { $0.1 < $0.0 }.count
        return UDPResult(dnsAnswered: dns, received: Set(sequence).count, reordered: reordered)
    }
}

/// 读取一个 HTTP/1.1 响应：状态码、正文长度与 SHA-256；连接在正文收全前结束时 `complete = false`。
private final class ResponseReader: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<InteropClient.Response>
    private var header = ByteBuffer()
    private var status: Int?
    private var length: Int?
    private var bytes = 0
    private var hasher = SHA256()
    private var prefix: [UInt8] = []
    private var done = false

    init(promise: EventLoopPromise<InteropClient.Response>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        if status == nil {
            header.writeBuffer(&buffer)
            guard let end = Self.headerEnd(header) else { return }
            let text = header.readString(length: end - header.readerIndex) ?? ""
            let lines = text.components(separatedBy: "\r\n")
            status = lines.first.flatMap { line in Int(line.split(separator: " ").dropFirst().first ?? "") } ?? 0
            for line in lines where line.lowercased().hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
            if status == 204 || status == 304 {
                length = 0
            }
            buffer = header
            header = ByteBuffer()
        }
        let view = buffer.readableBytesView
        bytes += view.count
        hasher.update(data: Array(view))
        if prefix.count < 65536 {
            prefix.append(contentsOf: view.prefix(65536 - prefix.count))
        }
        if let length, bytes >= length {
            finish(complete: true)
            context.close(promise: nil)
        }
    }

    static func headerEnd(_ buffer: ByteBuffer) -> Int? {
        let view = buffer.readableBytesView
        var index = view.startIndex
        while index + 3 < view.endIndex {
            if view[index] == 13, view[index + 1] == 10, view[index + 2] == 13, view[index + 3] == 10 {
                return index + 4
            }
            index += 1
        }
        return nil
    }

    private func finish(complete: Bool) {
        guard !done else { return }
        done = true
        promise.succeed(
            InteropClient.Response(
                status: status ?? 0, bytes: bytes, sha256: Array(hasher.finalize()), complete: complete,
                prefix: prefix))
    }

    /// 出站 Channel 允许半关闭：对端关闭表现为 `inputClosed`，不一定紧跟 `channelInactive`。
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            finish(complete: false)
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(complete: false)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        guard !done else { return }
        done = true
        promise.fail(error)
        context.close(promise: nil)
    }
}

/// 回环 UDP 服务：DNS 应答（`interop.example.com A` → 192.0.2.1）与回显。
final class InteropUDPServers: Sendable {
    let dns: any Channel
    let echo: any Channel

    private init(dns: any Channel, echo: any Channel) {
        self.dns = dns
        self.echo = echo
    }

    var dnsPort: UInt16 { UInt16(dns.localAddress?.port ?? 0) }
    var echoPort: UInt16 { UInt16(echo.localAddress?.port ?? 0) }

    static func start(group: any EventLoopGroup) async throws -> InteropUDPServers {
        func bind(_ handler: @escaping @Sendable () -> any ChannelHandler) async throws -> any Channel {
            try await DatagramBootstrap(group: group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(handler()) }
                }
                .bind(host: "127.0.0.1", port: 0).get()
        }
        return InteropUDPServers(dns: try await bind { DNSResponder() }, echo: try await bind { UDPEcho() })
    }

    func close() async throws {
        try await dns.close()
        try await echo.close()
    }

    /// `interop.example.com A`，ID 0x1234。
    static func query() -> ByteBuffer {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt16(0x1234))
        buffer.writeInteger(UInt16(0x0100))
        buffer.writeInteger(UInt16(1))
        buffer.writeRepeatingByte(0, count: 6)
        for label in ["interop", "example", "com"] {
            buffer.writeInteger(UInt8(label.utf8.count))
            buffer.writeString(label)
        }
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(UInt16(1))
        buffer.writeInteger(UInt16(1))
        return buffer
    }

    static func isExpectedAnswer(_ payload: ByteBuffer) -> Bool {
        let bytes = Array(payload.readableBytesView)
        return bytes.count >= 16 && bytes[0] == 0x12 && bytes[1] == 0x34 && bytes[7] == 1
            && Array(bytes.suffix(4)) == [192, 0, 2, 1]
    }
}

private final class DNSResponder: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let query = Array(envelope.data.readableBytesView)
        guard query.count > 12 else { return }
        var reply = context.channel.allocator.buffer(capacity: query.count + 16)
        reply.writeBytes(query[0..<2])
        reply.writeInteger(UInt16(0x8180))
        reply.writeInteger(UInt16(1))
        reply.writeInteger(UInt16(1))
        reply.writeRepeatingByte(0, count: 4)
        reply.writeBytes(query[12...])
        reply.writeBytes([0xC0, 0x0C, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 1])
        context.writeAndFlush(
            wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: reply)), promise: nil)
    }
}

private final class UDPEcho: ChannelInboundHandler, Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }
}
