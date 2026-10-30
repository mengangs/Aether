import AetherFoundation
import CBlake3
import Crypto
import Foundation
import NIOCore
import NIOPosix

/// Shadowsocks 2022 的加密方式（SIP022，docs/06 §8.4）。
public enum Shadowsocks2022Method: String, Sendable, Hashable, CaseIterable {
    case blake3AES128GCM = "2022-blake3-aes-128-gcm"
    case blake3AES256GCM = "2022-blake3-aes-256-gcm"
    case blake3ChaCha20Poly1305 = "2022-blake3-chacha20-poly1305"

    var algorithm: AEADAlgorithm {
        switch self {
        case .blake3AES128GCM: return .aes128GCM
        case .blake3AES256GCM: return .aes256GCM
        case .blake3ChaCha20Poly1305: return .chacha20Poly1305
        }
    }

    /// PSK、salt 与会话子密钥的长度。
    public var keyLength: Int { algorithm.keyLength }

    /// UDP 只支持 AES 变体：chacha20 变体的 UDP 需要 XChaCha20-Poly1305（M7）。
    public var supportsUDP: Bool { self != .blake3ChaCha20Poly1305 }
}

enum Shadowsocks2022KDF {
    static let context = "shadowsocks 2022 session subkey"

    /// 会话子密钥 `BLAKE3 derive_key(context, psk ‖ salt)`。
    static func sessionSubkey(psk: [UInt8], salt: [UInt8], length: Int) -> [UInt8] {
        var hasher = blake3_hasher()
        blake3_hasher_init_derive_key(&hasher, context)
        let material = psk + salt
        material.withUnsafeBytes { blake3_hasher_update(&hasher, $0.baseAddress, $0.count) }
        var output = [UInt8](repeating: 0, count: length)
        output.withUnsafeMutableBytes { blake3_hasher_finalize(&hasher, $0.baseAddress, length) }
        return output
    }
}

/// Shadowsocks 2022（SIP022，docs/06 §8.4）。PSK 为 `password` 的 Base64，长度必须与方法的密钥长度一致；
/// 多用户的 `iPSK:uPSK` 形式不支持。时间戳与服务器的偏差必须在 ±30 秒内。
///
/// - TCP：连接后立即发送 salt ‖ 固定长度头（类型 0、时间戳、变长头长度）‖ 变长头（目标地址、1–900 字节随机
///   填充，不带首包载荷）；之后每块 = 加密的 2 字节长度 ‖ 加密载荷（≤ 0xFFFF）。响应：salt ‖ 固定长度头
///   （类型 1、时间戳、请求 salt、首块长度）‖ 首块载荷，之后为普通块；类型、时间戳或请求 salt 不符时以 `NET-032` 关闭。
/// - UDP（AES 变体）：独立头（会话 ID ‖ 包 ID）以 PSK 做 AES 单块加密；正文以会话子密钥加密，nonce 为独立头明文的
///   后 12 字节；正文 = 类型 ‖ 时间戳 ‖ 填充长度 ‖ 填充 ‖ 地址 ‖ 数据（服务端方向在时间戳后多一个客户端会话 ID）。
public struct Shadowsocks2022Connector: OutboundConnector {
    public let name: String
    public let server: ProxyServer
    public let method: Shadowsocks2022Method
    public let obfs: SimpleObfsOptions?
    public let udpEnabled: Bool
    let psk: [UInt8]
    let clock: @Sendable () -> Date
    let random: @Sendable (Int) -> [UInt8]

    /// 时间戳允许的偏差（秒）。
    static let maxClockSkew: Double = 30
    /// 固定长度头之后的块载荷上限。
    static let maxChunkPayload = 0xFFFF

    public var capabilities: OutboundCapabilities {
        udpEnabled && method.supportsUDP ? [.tcp, .udp, .remoteResolve] : [.tcp, .remoteResolve]
    }

    /// `password` 不是长度正确的 Base64 PSK（或为多用户形式）时返回 nil。
    public init?(
        name: String, server: ProxyServer, method: Shadowsocks2022Method, password: String,
        obfs: SimpleObfsOptions? = nil, udpEnabled: Bool
    ) {
        self.init(
            name: name, server: server, method: method, password: password, obfs: obfs, udpEnabled: udpEnabled,
            clock: { Date() }, random: ShadowsocksConnector.randomSalt)
    }

    init?(
        name: String, server: ProxyServer, method: Shadowsocks2022Method, password: String,
        obfs: SimpleObfsOptions?, udpEnabled: Bool, clock: @escaping @Sendable () -> Date,
        random: @escaping @Sendable (Int) -> [UInt8]
    ) {
        guard !password.contains(":"), let psk = Data(base64Encoded: password), psk.count == method.keyLength else {
            return nil
        }
        self.name = name
        self.server = server
        self.method = method
        self.obfs = obfs
        self.udpEnabled = udpEnabled
        self.psk = Array(psk)
        self.clock = clock
        self.random = random
    }

    /// 客户端请求的前缀：salt ‖ 加密的固定长度头 ‖ 加密的变长头。返回前缀与之后数据块使用的加密状态。
    func requestPrefix(destination: Destination) throws -> (bytes: [UInt8], salt: [UInt8], sealer: Stream2022Sealer) {
        let salt = random(method.keyLength)
        var sealer = Stream2022Sealer(
            algorithm: method.algorithm,
            key: Shadowsocks2022KDF.sessionSubkey(psk: psk, salt: salt, length: method.keyLength))
        var variable = ByteBuffer()
        SOCKSAddress.write(destination, to: &variable)
        let draw = random(2)
        let paddingLength = 1 + (Int(draw[0]) << 8 | Int(draw[1])) % 900
        variable.writeInteger(UInt16(paddingLength))
        variable.writeBytes(random(paddingLength))
        var fixed: [UInt8] = [0]
        fixed += Self.timestamp(clock())
        fixed += [UInt8(variable.readableBytes >> 8), UInt8(variable.readableBytes & 0xFF)]
        var bytes = salt
        bytes += try sealer.seal(fixed)
        bytes += try sealer.seal(Array(variable.readableBytesView))
        return (bytes, salt, sealer)
    }

    static func timestamp(_ date: Date) -> [UInt8] {
        let seconds = UInt64(max(0, date.timeIntervalSince1970))
        return (0..<8).map { UInt8(truncatingIfNeeded: seconds >> UInt64(56 - 8 * $0)) }
    }

    static func seconds(_ bytes: ArraySlice<UInt8>) -> Double {
        Double(bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
    }

    public func connect(to destination: Destination, context: DialContext) -> EventLoopFuture<any Channel> {
        let prefix: (bytes: [UInt8], salt: [UInt8], sealer: Stream2022Sealer)
        do {
            prefix = try requestPrefix(destination: destination)
        } catch {
            return context.eventLoop.makeFailedFuture(error)
        }
        let method = self.method
        let psk = self.psk
        let clock = self.clock
        let obfs = self.obfs
        let serverHost = server.host
        let serverPort = server.port
        return server.dial(context: context).flatMap { channel in
            channel.eventLoop.makeCompletedFuture { () -> any Channel in
                try obfs?.install(on: channel, serverHost: serverHost, serverPort: serverPort)
                try channel.pipeline.syncOperations.addHandler(
                    Shadowsocks2022StreamHandler(
                        prefix: prefix.bytes, sealer: prefix.sealer,
                        opener: Stream2022Opener(method: method, psk: psk, requestSalt: prefix.salt, clock: clock)))
                return channel
            }.closingOnFailure(channel)
        }
    }

    public func openUDP(context: DialContext) -> EventLoopFuture<any OutboundUDPAssociation> {
        guard udpEnabled, method.supportsUDP else {
            let reason = method.supportsUDP ? "\(name) has UDP relay disabled" : "\(method.rawValue) UDP arrives in M7"
            return context.eventLoop.makeFailedFuture(NetworkError(.netPolicyNoUDP, reason))
        }
        let port = server.port
        let codec = Shadowsocks2022UDPCodec(
            method: method, psk: psk, sessionID: random(8), clock: clock, random: random)
        return ServerAddressSelection.resolve(
            server.host, preference: server.addressPreference, resolver: context.serverResolver,
            eventLoop: context.eventLoop
        ).flatMap { address in
            guard let relay = try? SocketAddress(ipAddress: address.description, port: Int(port)), let codec else {
                return context.eventLoop.makeFailedFuture(NetworkError(.netUnreachable, "Invalid address \(address)"))
            }
            return Shadowsocks2022UDPAssociation.open(eventLoop: context.eventLoop, relay: relay, codec: codec)
                .map { $0 as any OutboundUDPAssociation }
        }
    }
}

// MARK: - TCP

/// 请求方向：每次 AEAD 操作用一个小端递增 nonce。
struct Stream2022Sealer {
    let algorithm: AEADAlgorithm
    let key: SymmetricKey
    private var nonce = AEADNonceCounter()

    init(algorithm: AEADAlgorithm, key: [UInt8]) {
        self.algorithm = algorithm
        self.key = SymmetricKey(data: key)
    }

    mutating func seal(_ plain: [UInt8]) throws -> [UInt8] {
        try algorithm.seal(plain, key: key, nonce: nonce.next())
    }

    /// 一个数据块：加密的 2 字节长度 ‖ 加密载荷。
    mutating func sealChunk(_ payload: [UInt8], into output: inout ByteBuffer) throws {
        output.writeBytes(try seal([UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]))
        output.writeBytes(try seal(payload))
    }
}

/// 响应方向：salt → 固定长度头（校验类型、时间戳、请求 salt）→ 首块 → 普通块。只缓存不完整的块。
struct Stream2022Opener {
    private enum Stage {
        case salt
        case fixedHeader
        case payload(Int)
        case length
    }

    let method: Shadowsocks2022Method
    let psk: [UInt8]
    let requestSalt: [UInt8]
    let clock: @Sendable () -> Date
    private var stage = Stage.salt
    private var key: SymmetricKey?
    private var nonce = AEADNonceCounter()
    private var pending = ByteBuffer()

    init(method: Shadowsocks2022Method, psk: [UInt8], requestSalt: [UInt8], clock: @escaping @Sendable () -> Date) {
        self.method = method
        self.psk = psk
        self.requestSalt = requestSalt
        self.clock = clock
    }

    private mutating func open(_ sealed: [UInt8]) throws -> [UInt8] {
        guard let key else { throw NetworkError(.netProtocolError, "Shadowsocks 2022 stream without key") }
        do {
            return try method.algorithm.open(sealed, key: key, nonce: nonce.next())
        } catch {
            throw NetworkError(.netProtocolError, "Shadowsocks 2022 response failed authentication")
        }
    }

    /// 消费 `input`，把解密出的载荷追加到 `output`。
    mutating func decode(_ input: inout ByteBuffer, into output: inout ByteBuffer) throws {
        pending.writeBuffer(&input)
        let tag = AEADAlgorithm.tagLength
        loop: while true {
            switch stage {
            case .salt:
                guard let salt = pending.readBytes(length: method.keyLength) else { break loop }
                key = SymmetricKey(
                    data: Shadowsocks2022KDF.sessionSubkey(psk: psk, salt: salt, length: method.keyLength))
                stage = .fixedHeader
            case .fixedHeader:
                let size = 1 + 8 + method.keyLength + 2
                guard let sealed = pending.readBytes(length: size + tag) else { break loop }
                let header = try open(sealed)
                guard header.count == size, header[0] == 1 else {
                    throw NetworkError(.netProtocolError, "Shadowsocks 2022 response has the wrong type")
                }
                let skew = abs(Shadowsocks2022Connector.seconds(header[1..<9]) - clock().timeIntervalSince1970)
                guard skew <= Shadowsocks2022Connector.maxClockSkew else {
                    throw NetworkError(.netProtocolError, "Shadowsocks 2022 response timestamp is \(Int(skew)) s off")
                }
                guard Array(header[9..<(9 + method.keyLength)]) == requestSalt else {
                    throw NetworkError(.netProtocolError, "Shadowsocks 2022 response is for another request")
                }
                stage = .payload(Int(header[size - 2]) << 8 | Int(header[size - 1]))
            case .payload(let length):
                guard let sealed = pending.readBytes(length: length + tag) else { break loop }
                output.writeBytes(try open(sealed))
                stage = .length
            case .length:
                guard let sealed = pending.readBytes(length: 2 + tag) else { break loop }
                let length = try open(sealed)
                guard length.count == 2 else {
                    throw NetworkError(.netProtocolError, "Malformed Shadowsocks 2022 chunk")
                }
                stage = .payload(Int(length[0]) << 8 | Int(length[1]))
            }
        }
        pending.discardReadBytes()
    }
}

/// 管线中的 Shadowsocks 2022 TCP 编解码：加入时发送请求前缀，之后双向加解密；解密或校验失败以 `NET-032` 关闭。
final class Shadowsocks2022StreamHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let prefix: [UInt8]
    private var sealer: Stream2022Sealer
    private var opener: Stream2022Opener
    private var failed = false

    init(prefix: [UInt8], sealer: Stream2022Sealer, opener: Stream2022Opener) {
        self.prefix = prefix
        self.sealer = sealer
        self.opener = opener
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: prefix)), promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var input = unwrapOutboundIn(data)
        var output = context.channel.allocator.buffer(capacity: input.readableBytes + 64)
        do {
            repeat {
                let count = min(input.readableBytes, Shadowsocks2022Connector.maxChunkPayload)
                try sealer.sealChunk(input.readBytes(length: count) ?? [], into: &output)
            } while input.readableBytes > 0
        } catch {
            promise?.fail(error)
            fail(context: context, "\(error)")
            return
        }
        context.write(wrapOutboundOut(output), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed else { return }
        var input = unwrapInboundIn(data)
        var output = context.channel.allocator.buffer(capacity: input.readableBytes)
        do {
            try opener.decode(&input, into: &output)
        } catch {
            fail(context: context, (error as? NetworkError)?.debugDetails ?? "\(error)")
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
extension Shadowsocks2022StreamHandler: Sendable {}

// MARK: - UDP

/// Shadowsocks 2022 的 UDP 包（AES 变体）。客户端会话 ID 每个关联一个，包 ID 从 0 递增；
/// 服务端会话的子密钥缓存最近 4 个（服务端换会话时重新派生）。
final class Shadowsocks2022UDPCodec: @unchecked Sendable {
    let method: Shadowsocks2022Method
    private let psk: [UInt8]
    private let block: AESBlock
    private let sessionID: [UInt8]
    private let sessionKey: SymmetricKey
    private let clock: @Sendable () -> Date
    private let random: @Sendable (Int) -> [UInt8]
    private var packetID: UInt64 = 0
    private var serverKeys: [(id: [UInt8], key: SymmetricKey)] = []

    init?(
        method: Shadowsocks2022Method, psk: [UInt8], sessionID: [UInt8], clock: @escaping @Sendable () -> Date,
        random: @escaping @Sendable (Int) -> [UInt8]
    ) {
        guard method.supportsUDP, let block = AESBlock(key: psk), sessionID.count == 8 else { return nil }
        self.method = method
        self.psk = psk
        self.block = block
        self.sessionID = sessionID
        self.clock = clock
        self.random = random
        sessionKey = SymmetricKey(
            data: Shadowsocks2022KDF.sessionSubkey(psk: psk, salt: sessionID, length: method.keyLength))
    }

    func seal(_ payload: ByteBuffer, destination: Destination, allocator: ByteBufferAllocator) throws -> ByteBuffer {
        var header = sessionID
        header += (0..<8).map { UInt8(truncatingIfNeeded: packetID >> UInt64(56 - 8 * $0)) }
        packetID &+= 1
        guard let encryptedHeader = block.encrypt(header) else {
            throw NetworkError(.netProtocolError, "Shadowsocks 2022 header encryption failed")
        }
        var body = allocator.buffer(capacity: 11 + SOCKSAddress.length(of: destination) + payload.readableBytes)
        body.writeInteger(UInt8(0))
        body.writeBytes(Shadowsocks2022Connector.timestamp(clock()))
        body.writeInteger(UInt16(0))
        SOCKSAddress.write(destination, to: &body)
        var payload = payload
        body.writeBuffer(&payload)
        var packet = allocator.buffer(capacity: 16 + body.readableBytes + AEADAlgorithm.tagLength)
        packet.writeBytes(encryptedHeader)
        packet.writeBytes(
            try method.algorithm.seal(Array(body.readableBytesView), key: sessionKey, nonce: Array(header[4..<16])))
        return packet
    }

    /// 解开回包；格式、认证、类型、时间戳或客户端会话 ID 不符时返回 nil。
    func open(_ packet: ByteBuffer, allocator: ByteBufferAllocator) -> (source: Destination, payload: ByteBuffer)? {
        var packet = packet
        guard let encryptedHeader = packet.readBytes(length: 16), let header = block.decrypt(encryptedHeader) else {
            return nil
        }
        let serverSession = Array(header[0..<8])
        let key = serverKey(for: serverSession)
        guard
            let plain = try? method.algorithm.open(
                Array(packet.readableBytesView), key: key, nonce: Array(header[4..<16])),
            plain.count >= 19, plain[0] == 1,
            abs(Shadowsocks2022Connector.seconds(plain[1..<9]) - clock().timeIntervalSince1970)
                <= Shadowsocks2022Connector.maxClockSkew,
            Array(plain[9..<17]) == sessionID
        else { return nil }
        let padding = Int(plain[17]) << 8 | Int(plain[18])
        guard plain.count >= 19 + padding else { return nil }
        let rest = allocator.buffer(bytes: plain[(19 + padding)...])
        guard case .parsed(let source, let length) = SOCKSAddress.parse(rest) else { return nil }
        return (
            source, rest.getSlice(at: rest.readerIndex + length, length: rest.readableBytes - length) ?? ByteBuffer()
        )
    }

    private func serverKey(for session: [UInt8]) -> SymmetricKey {
        if let cached = serverKeys.first(where: { $0.id == session }) {
            return cached.key
        }
        let key = SymmetricKey(
            data: Shadowsocks2022KDF.sessionSubkey(psk: psk, salt: session, length: method.keyLength))
        if serverKeys.count >= 4 {
            serverKeys.removeFirst()
        }
        serverKeys.append((session, key))
        return key
    }
}

/// 经 Shadowsocks 2022 服务器转发的 UDP 关联：一个 UDP socket，只接受来自服务器地址且能解开的包。
final class Shadowsocks2022UDPAssociation: OutboundUDPAssociation, @unchecked Sendable {
    var onDatagram: ((ByteBuffer, Destination) -> Void)?
    var closeFuture: EventLoopFuture<Void> { closePromise.futureResult }
    /// 丢弃的数据报数（加密失败、来源不符、无法解开）。
    private(set) var dropped = 0

    private let datagram: any Channel
    private let relay: SocketAddress
    private let codec: Shadowsocks2022UDPCodec
    private let closePromise: EventLoopPromise<Void>
    private var closed = false

    private init(datagram: any Channel, relay: SocketAddress, codec: Shadowsocks2022UDPCodec) {
        self.datagram = datagram
        self.relay = relay
        self.codec = codec
        closePromise = datagram.eventLoop.makePromise()
    }

    static func open(eventLoop: any EventLoop, relay: SocketAddress, codec: Shadowsocks2022UDPCodec)
        -> EventLoopFuture<Shadowsocks2022UDPAssociation>
    {
        let receiver = Shadowsocks2022UDPReceiver()
        return DatagramBootstrap(group: eventLoop)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(receiver) }
            }
            .bind(host: relay.protocol == .inet6 ? "::" : "0.0.0.0", port: 0)
            .map { datagram in
                let association = Shadowsocks2022UDPAssociation(datagram: datagram, relay: relay, codec: codec)
                receiver.association = association
                datagram.closeFuture.whenComplete { _ in association.close() }
                return association
            }
            .flatMapErrorThrowing { throw NetworkErrorMapping.map($0) }
    }

    func send(_ payload: ByteBuffer, to destination: Destination) {
        guard !closed, let packet = try? codec.seal(payload, destination: destination, allocator: datagram.allocator)
        else {
            dropped += 1
            return
        }
        datagram.writeAndFlush(AddressedEnvelope(remoteAddress: relay, data: packet), promise: nil)
    }

    fileprivate func received(_ envelope: AddressedEnvelope<ByteBuffer>) {
        guard !closed else { return }
        guard envelope.remoteAddress == relay,
            let (source, payload) = codec.open(envelope.data, allocator: datagram.allocator)
        else {
            dropped += 1
            return
        }
        onDatagram?(payload, source)
    }

    func close() {
        guard !closed else { return }
        closed = true
        onDatagram = nil
        datagram.close(promise: nil)
        closePromise.succeed(())
    }
}

private final class Shadowsocks2022UDPReceiver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    weak var association: Shadowsocks2022UDPAssociation?

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        association?.received(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {}
}
