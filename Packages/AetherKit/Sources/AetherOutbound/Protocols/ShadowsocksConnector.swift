import AetherFoundation
import Crypto
import NIOCore
import NIOPosix

/// Shadowsocks AEAD（shadowsocks.org AEAD 规范，docs/06 §8.4）。
///
/// - TCP：连接后立即发送 salt 与只含目标地址（SOCKS 地址格式）的首块，使服务端先说话的协议也能工作；
///   之后每次写入加密为若干块（载荷 ≤ 0x3FFF）。服务端没有握手应答，密码错误表现为服务端关闭连接或
///   响应无法通过认证（`NET-032`）。
/// - UDP：每包独立 salt、nonce 为零，载荷 = SOCKS 地址 ‖ 数据；一个关联一个 UDP socket，只接受来自服务器地址的包。
/// - `obfs`：在 TCP 与协议之间叠加 simple-obfs http（`SimpleObfsHTTPHandler`）或 tls（`SimpleObfsTLSHandler`）。
public struct ShadowsocksConnector: OutboundConnector {
    public let name: String
    public let server: ProxyServer
    public let method: ShadowsocksAEADMethod
    public let obfs: SimpleObfsOptions?
    public let udpEnabled: Bool
    let masterKey: [UInt8]
    /// 生成 salt（测试注入固定值）。
    let saltGenerator: @Sendable (Int) -> [UInt8]

    public var capabilities: OutboundCapabilities {
        udpEnabled ? [.tcp, .udp, .remoteResolve] : [.tcp, .remoteResolve]
    }

    public init(
        name: String, server: ProxyServer, method: ShadowsocksAEADMethod, password: String,
        obfs: SimpleObfsOptions? = nil, udpEnabled: Bool
    ) {
        self.init(
            name: name, server: server, method: method, password: password, obfs: obfs, udpEnabled: udpEnabled,
            saltGenerator: Self.randomSalt)
    }

    init(
        name: String, server: ProxyServer, method: ShadowsocksAEADMethod, password: String,
        obfs: SimpleObfsOptions?, udpEnabled: Bool, saltGenerator: @escaping @Sendable (Int) -> [UInt8]
    ) {
        self.name = name
        self.server = server
        self.method = method
        self.obfs = obfs
        self.udpEnabled = udpEnabled
        self.masterKey = ShadowsocksKDF.bytesToKey(password: Array(password.utf8), length: method.keyLength)
        self.saltGenerator = saltGenerator
    }

    @Sendable static func randomSalt(_ length: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<length).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    public func connect(to destination: Destination, context: DialContext) -> EventLoopFuture<any Channel> {
        let method = self.method
        let masterKey = self.masterKey
        let salt = saltGenerator(method.saltLength)
        let obfs = self.obfs
        let serverHost = server.host
        let serverPort = server.port
        return server.dial(context: context).flatMap { channel in
            channel.eventLoop.makeCompletedFuture { () -> any Channel in
                try obfs?.install(on: channel, serverHost: serverHost, serverPort: serverPort)
                var header = channel.allocator.buffer(capacity: SOCKSAddress.length(of: destination))
                SOCKSAddress.write(destination, to: &header)
                try channel.pipeline.syncOperations.addHandler(
                    ShadowsocksStreamHandler(
                        encoder: ShadowsocksStreamEncoder(method: method, masterKey: masterKey, salt: salt),
                        decoder: ShadowsocksStreamDecoder(method: method, masterKey: masterKey), header: header))
                return channel
            }.closingOnFailure(channel)
        }
    }

    public func openUDP(context: DialContext) -> EventLoopFuture<any OutboundUDPAssociation> {
        guard udpEnabled else {
            return context.eventLoop.makeFailedFuture(NetworkError(.netPolicyNoUDP, "\(name) has UDP relay disabled"))
        }
        let method = self.method
        let masterKey = self.masterKey
        let saltGenerator = self.saltGenerator
        let port = server.port
        return ServerAddressSelection.resolve(
            server.host, preference: server.addressPreference, resolver: context.serverResolver,
            eventLoop: context.eventLoop
        ).flatMap { address in
            let relay: SocketAddress
            do {
                relay = try SocketAddress(ipAddress: address.description, port: Int(port))
            } catch {
                return context.eventLoop.makeFailedFuture(NetworkError(.netUnreachable, "Invalid address \(address)"))
            }
            return ShadowsocksUDPAssociation.open(
                eventLoop: context.eventLoop, relay: relay,
                codec: ShadowsocksUDPCodec(method: method, masterKey: masterKey), saltGenerator: saltGenerator
            ).map { $0 as any OutboundUDPAssociation }
        }
    }
}

// MARK: - TCP 流

/// TCP 流的加密端：第一次输出前置 salt；每块 = 加密的 2 字节大端长度 ‖ 标签 ‖ 加密载荷 ‖ 标签。
struct ShadowsocksStreamEncoder {
    static let maxChunkPayload = 0x3FFF

    private let algorithm: AEADAlgorithm
    private let key: SymmetricKey
    private var nonce = AEADNonceCounter()
    private var salt: [UInt8]?

    init(method: ShadowsocksAEADMethod, masterKey: [UInt8], salt: [UInt8]) {
        algorithm = method.algorithm
        key = ShadowsocksKDF.subkey(masterKey: masterKey, salt: salt, length: method.keyLength)
        self.salt = salt
    }

    /// 加密 `input` 的全部可读字节并追加到 `output`。
    mutating func encode(_ input: ByteBuffer, into output: inout ByteBuffer) throws {
        if let salt {
            output.writeBytes(salt)
            self.salt = nil
        }
        var input = input
        repeat {
            let count = min(input.readableBytes, Self.maxChunkPayload)
            let chunk = input.readBytes(length: count) ?? []
            output.writeBytes(
                try algorithm.seal([UInt8(count >> 8), UInt8(count & 0xFF)], key: key, nonce: nonce.next()))
            output.writeBytes(try algorithm.seal(chunk, key: key, nonce: nonce.next()))
        } while input.readableBytes > 0
    }
}

/// TCP 流的解密端：先读 salt，再逐块解密。内部只缓存不完整的块（< 1 块，约 16 KiB）。
struct ShadowsocksStreamDecoder {
    enum Failure: Error {
        case authentication
        case oversizedChunk(Int)
    }

    private let method: ShadowsocksAEADMethod
    private let masterKey: [UInt8]
    private var key: SymmetricKey?
    private var nonce = AEADNonceCounter()
    private var pending = ByteBuffer()
    /// 已解密长度、等待载荷的块。
    private var payloadLength: Int?

    init(method: ShadowsocksAEADMethod, masterKey: [UInt8]) {
        self.method = method
        self.masterKey = masterKey
    }

    /// 消费 `input` 的全部字节，把解密出的载荷追加到 `output`。
    mutating func decode(_ input: inout ByteBuffer, into output: inout ByteBuffer) throws {
        pending.writeBuffer(&input)
        let tag = AEADAlgorithm.tagLength
        if key == nil {
            guard let salt = pending.readBytes(length: method.saltLength) else { return }
            key = ShadowsocksKDF.subkey(masterKey: masterKey, salt: salt, length: method.keyLength)
        }
        guard let key else { return }
        while true {
            if let length = payloadLength {
                guard let sealed = pending.readBytes(length: length + tag) else { break }
                guard let plain = try? method.algorithm.open(sealed, key: key, nonce: nonce.next()) else {
                    throw Failure.authentication
                }
                output.writeBytes(plain)
                payloadLength = nil
            } else {
                guard let sealed = pending.readBytes(length: 2 + tag) else { break }
                guard let plain = try? method.algorithm.open(sealed, key: key, nonce: nonce.next()), plain.count == 2
                else { throw Failure.authentication }
                let length = Int(plain[0]) << 8 | Int(plain[1])
                guard length <= ShadowsocksStreamEncoder.maxChunkPayload else { throw Failure.oversizedChunk(length) }
                payloadLength = length
            }
        }
        pending.discardReadBytes()
    }
}

/// 管线中的 Shadowsocks TCP 编解码：加入时发送 salt 与目标地址块，之后双向加解密。
/// 解密失败时以 `NET-032` 报错并关闭连接。
final class ShadowsocksStreamHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var encoder: ShadowsocksStreamEncoder
    private var decoder: ShadowsocksStreamDecoder
    private let header: ByteBuffer
    private var failed = false

    init(encoder: ShadowsocksStreamEncoder, decoder: ShadowsocksStreamDecoder, header: ByteBuffer) {
        self.encoder = encoder
        self.decoder = decoder
        self.header = header
    }

    func handlerAdded(context: ChannelHandlerContext) {
        var output = context.channel.allocator.buffer(capacity: header.readableBytes + 64)
        do {
            try encoder.encode(header, into: &output)
            context.writeAndFlush(wrapOutboundOut(output), promise: nil)
        } catch {
            fail(context: context, "Shadowsocks encryption failed: \(error)")
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let input = unwrapOutboundIn(data)
        var output = context.channel.allocator.buffer(capacity: input.readableBytes + 64)
        do {
            try encoder.encode(input, into: &output)
            context.write(wrapOutboundOut(output), promise: promise)
        } catch {
            promise?.fail(error)
            fail(context: context, "Shadowsocks encryption failed: \(error)")
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed else { return }
        var input = unwrapInboundIn(data)
        var output = context.channel.allocator.buffer(capacity: input.readableBytes)
        do {
            try decoder.decode(&input, into: &output)
        } catch {
            fail(context: context, "Shadowsocks response failed authentication (\(error))")
            return
        }
        if output.readableBytes > 0 {
            context.fireChannelRead(wrapInboundOut(output))
        }
    }

    private func fail(context: ChannelHandlerContext, _ message: String) {
        guard !failed else { return }
        failed = true
        context.fireErrorCaught(NetworkError(.netProtocolError, message))
        context.close(promise: nil)
    }
}

@available(*, unavailable)
extension ShadowsocksStreamHandler: Sendable {}

// MARK: - UDP

/// UDP 包：salt ‖ AEAD(subkey(salt), nonce 0, SOCKS 地址 ‖ 数据)。
struct ShadowsocksUDPCodec: Sendable {
    let method: ShadowsocksAEADMethod
    let masterKey: [UInt8]

    func seal(
        _ payload: ByteBuffer, destination: Destination, salt: [UInt8], allocator: ByteBufferAllocator
    ) throws -> ByteBuffer {
        var plain = allocator.buffer(capacity: SOCKSAddress.length(of: destination) + payload.readableBytes)
        SOCKSAddress.write(destination, to: &plain)
        var payload = payload
        plain.writeBuffer(&payload)
        let key = ShadowsocksKDF.subkey(masterKey: masterKey, salt: salt, length: method.keyLength)
        var packet = allocator.buffer(capacity: salt.count + plain.readableBytes + AEADAlgorithm.tagLength)
        packet.writeBytes(salt)
        packet.writeBytes(
            try method.algorithm.seal(Array(plain.readableBytesView), key: key, nonce: AEADNonceCounter().bytes))
        return packet
    }

    /// 解开回包，返回来源与数据；认证失败或格式错误返回 nil。
    func open(_ packet: ByteBuffer, allocator: ByteBufferAllocator) -> (source: Destination, payload: ByteBuffer)? {
        var packet = packet
        guard let salt = packet.readBytes(length: method.saltLength) else { return nil }
        let key = ShadowsocksKDF.subkey(masterKey: masterKey, salt: salt, length: method.keyLength)
        guard
            let plain = try? method.algorithm.open(
                Array(packet.readableBytesView), key: key, nonce: AEADNonceCounter().bytes)
        else { return nil }
        let buffer = allocator.buffer(bytes: plain)
        guard case .parsed(let source, let length) = SOCKSAddress.parse(buffer) else { return nil }
        return (
            source,
            buffer.getSlice(at: buffer.readerIndex + length, length: buffer.readableBytes - length) ?? ByteBuffer()
        )
    }
}

/// 经 Shadowsocks 服务器转发的 UDP 关联：一个 UDP socket，发往服务器，只接受来自服务器地址的包；
/// 无法解开的回包丢弃并计数。
public final class ShadowsocksUDPAssociation: OutboundUDPAssociation, @unchecked Sendable {
    public var onDatagram: ((ByteBuffer, Destination) -> Void)?
    public var closeFuture: EventLoopFuture<Void> { closePromise.futureResult }
    /// 丢弃的数据报数（加密失败、来源不符、无法解开）。
    public private(set) var dropped = 0

    private let datagram: any Channel
    private let relay: SocketAddress
    private let codec: ShadowsocksUDPCodec
    private let saltGenerator: @Sendable (Int) -> [UInt8]
    private let closePromise: EventLoopPromise<Void>
    private var closed = false

    private init(
        datagram: any Channel, relay: SocketAddress, codec: ShadowsocksUDPCodec,
        saltGenerator: @escaping @Sendable (Int) -> [UInt8]
    ) {
        self.datagram = datagram
        self.relay = relay
        self.codec = codec
        self.saltGenerator = saltGenerator
        closePromise = datagram.eventLoop.makePromise()
    }

    static func open(
        eventLoop: any EventLoop, relay: SocketAddress, codec: ShadowsocksUDPCodec,
        saltGenerator: @escaping @Sendable (Int) -> [UInt8]
    ) -> EventLoopFuture<ShadowsocksUDPAssociation> {
        let receiver = ShadowsocksUDPReceiver()
        return DatagramBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(receiver) }
            }
            .bind(host: relay.protocol == .inet6 ? "::" : "0.0.0.0", port: 0)
            .map { datagram in
                let association = ShadowsocksUDPAssociation(
                    datagram: datagram, relay: relay, codec: codec, saltGenerator: saltGenerator)
                receiver.association = association
                datagram.closeFuture.whenComplete { _ in association.close() }
                return association
            }
            .flatMapErrorThrowing { throw NetworkErrorMapping.map($0) }
    }

    public func send(_ payload: ByteBuffer, to destination: Destination) {
        guard !closed else { return }
        guard
            let packet = try? codec.seal(
                payload, destination: destination, salt: saltGenerator(codec.method.saltLength),
                allocator: datagram.allocator)
        else {
            dropped += 1
            return
        }
        datagram.writeAndFlush(AddressedEnvelope(remoteAddress: relay, data: packet), promise: nil)
    }

    func received(_ envelope: AddressedEnvelope<ByteBuffer>) {
        guard !closed else { return }
        guard envelope.remoteAddress == relay,
            let (source, payload) = codec.open(envelope.data, allocator: datagram.allocator)
        else {
            dropped += 1
            return
        }
        onDatagram?(payload, source)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        onDatagram = nil
        datagram.close(promise: nil)
        closePromise.succeed(())
    }
}

private final class ShadowsocksUDPReceiver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    weak var association: ShadowsocksUDPAssociation?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        association?.received(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {}
}
