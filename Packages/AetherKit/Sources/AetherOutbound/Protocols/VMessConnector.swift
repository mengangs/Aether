import AetherFoundation
import Crypto
import Foundation
import NIOCore

/// VMess 的数据加密方式（docs/04 §5.5 `encrypt-method`；`auto` 取 AES-128-GCM）。
public enum VMessSecurity: Sendable, Hashable {
    case aes128GCM
    case chacha20Poly1305
    case none

    var code: UInt8 {
        switch self {
        case .aes128GCM: return 0x03
        case .chacha20Poly1305: return 0x04
        case .none: return 0x05
        }
    }
}

/// VMess AEAD（xtls.github.io VMess 协议文档，docs/06 §8.4）。只实现 AEAD 请求头（`alterId = 0`）；
/// 选项只置 ChunkStream，不置 ChunkMasking 与 GlobalPadding（🔬 由互通测试确认服务端接受）。
///
/// - 请求头：AuthID（时间戳 ‖ 随机数 ‖ CRC32，AES-128 单块加密）‖ AEAD 加密的指令长度 ‖ 8 字节连接 nonce ‖
///   AEAD 加密的指令；指令含数据 IV 与密钥、响应认证字节、选项、加密方式、命令、端口与地址、随机填充与 FNV-1a 校验。
///   连接后立即发送。
/// - 数据：2 字节长度 ‖ 加密块（nonce = 2 字节计数 ‖ IV[2..<12]）；空块表示该方向结束。
/// - 响应头在第一批数据到达时解密并校验响应认证字节，不阻塞连接的返回；校验失败以 `NET-032` 关闭。
/// - UDP：每个目标一条连接（命令 2），每个数据块是一个数据报。
public struct VMessConnector: OutboundConnector {
    public let name: String
    public let server: ProxyServer
    public let security: VMessSecurity
    public let udpEnabled: Bool
    let commandKey: [UInt8]
    /// 当前时间（AuthID 的时间戳；测试注入）。
    let clock: @Sendable () -> Date
    /// 随机字节（测试注入）。
    let random: @Sendable (Int) -> [UInt8]

    public var capabilities: OutboundCapabilities {
        udpEnabled ? [.tcp, .udp, .remoteResolve] : [.tcp, .remoteResolve]
    }

    /// `uuid` 无法解析时返回 nil。
    public init?(name: String, server: ProxyServer, uuid: String, security: VMessSecurity, udpEnabled: Bool) {
        self.init(
            name: name, server: server, uuid: uuid, security: security, udpEnabled: udpEnabled, clock: { Date() },
            random: ShadowsocksConnector.randomSalt)
    }

    init?(
        name: String, server: ProxyServer, uuid: String, security: VMessSecurity, udpEnabled: Bool,
        clock: @escaping @Sendable () -> Date, random: @escaping @Sendable (Int) -> [UInt8]
    ) {
        guard let parsed = UUID(uuidString: uuid) else { return nil }
        self.name = name
        self.server = server
        self.security = security
        self.udpEnabled = udpEnabled
        self.clock = clock
        self.random = random
        let uuidBytes = withUnsafeBytes(of: parsed.uuid) { Array($0) }
        commandKey = Array(Insecure.MD5.hash(data: uuidBytes + Array("c48619fe-8f02-49e0-b9e9-edf763e17e21".utf8)))
    }

    static let commandTCP: UInt8 = 0x01
    static let commandUDP: UInt8 = 0x02

    /// 一条连接的数据密钥（请求方向随机，响应方向为其 SHA-256 的前 16 字节）。
    struct Session {
        var requestKey: [UInt8]
        var requestIV: [UInt8]
        var responseAuth: UInt8
        var security: VMessSecurity

        var responseKey: [UInt8] { Array(SHA256.hash(data: requestKey).prefix(16)) }
        var responseIV: [UInt8] { Array(SHA256.hash(data: requestIV).prefix(16)) }
    }

    func makeSession() -> Session {
        let bytes = random(33)
        return Session(
            requestKey: Array(bytes[0..<16]), requestIV: Array(bytes[16..<32]), responseAuth: bytes[32],
            security: security)
    }

    /// 明文指令。
    func instruction(session: Session, command: UInt8, destination: Destination) -> [UInt8] {
        let padding = Int(random(1)[0] & 0x0F)
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt8(1))
        buffer.writeBytes(session.requestIV)
        buffer.writeBytes(session.requestKey)
        buffer.writeInteger(session.responseAuth)
        buffer.writeInteger(UInt8(0x01))  // 选项：只有 ChunkStream。
        buffer.writeInteger(UInt8(padding << 4) | session.security.code)
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(command)
        PortFirstAddress.write(destination, to: &buffer)
        buffer.writeBytes(random(padding))
        var bytes = Array(buffer.readableBytesView)
        let checksum = FNV1a32.hash(bytes)
        bytes += [
            UInt8(checksum >> 24), UInt8(truncatingIfNeeded: checksum >> 16),
            UInt8(truncatingIfNeeded: checksum >> 8), UInt8(truncatingIfNeeded: checksum),
        ]
        return bytes
    }

    /// AuthID：时间戳（秒，大端 8 字节）‖ 4 字节随机数 ‖ 前 12 字节的 CRC32，再以 AES-128 单块加密。
    func authID() throws -> [UInt8] {
        let seconds = UInt64(max(0, clock().timeIntervalSince1970))
        var plain: [UInt8] = (0..<8).map { UInt8(truncatingIfNeeded: seconds >> UInt64(56 - 8 * $0)) }
        plain += random(4)
        let crc = CRC32.checksum(plain)
        plain += [
            UInt8(crc >> 24), UInt8(truncatingIfNeeded: crc >> 16), UInt8(truncatingIfNeeded: crc >> 8),
            UInt8(truncatingIfNeeded: crc),
        ]
        let key = VMessKDF.derive16(commandKey, path: [Array("AES Auth ID Encryption".utf8)])
        guard let cipher = AESBlock(key: key), let encrypted = cipher.encrypt(plain) else {
            throw NetworkError(.netProtocolError, "VMess AuthID encryption failed")
        }
        return encrypted
    }

    /// 完整的 AEAD 请求头。
    func sealedHeader(session: Session, command: UInt8, destination: Destination) throws -> [UInt8] {
        let id = try authID()
        let nonce = random(8)
        let plain = instruction(session: session, command: command, destination: destination)
        func key(_ label: String) -> SymmetricKey {
            SymmetricKey(data: VMessKDF.derive16(commandKey, path: [Array(label.utf8), id, nonce]))
        }
        func iv(_ label: String) -> [UInt8] {
            Array(VMessKDF.derive(commandKey, path: [Array(label.utf8), id, nonce]).prefix(12))
        }
        let length = try AEADAlgorithm.aes128GCM.seal(
            [UInt8(plain.count >> 8), UInt8(plain.count & 0xFF)], key: key("VMess Header AEAD Key_Length"),
            nonce: iv("VMess Header AEAD Nonce_Length"), additionalData: id)
        let payload = try AEADAlgorithm.aes128GCM.seal(
            plain, key: key("VMess Header AEAD Key"), nonce: iv("VMess Header AEAD Nonce"), additionalData: id)
        return id + length + nonce + payload
    }

    private func dial(
        command: UInt8, destination: Destination, packetMode: Bool, context: DialContext
    ) -> EventLoopFuture<any Channel> {
        let session = makeSession()
        let header: [UInt8]
        do {
            header = try sealedHeader(session: session, command: command, destination: destination)
        } catch {
            return context.eventLoop.makeFailedFuture(error)
        }
        return server.dial(context: context).flatMap { channel in
            channel.eventLoop.makeCompletedFuture { () -> any Channel in
                try channel.pipeline.syncOperations.addHandler(
                    VMessStreamHandler(session: session, header: header, packetMode: packetMode))
                return channel
            }.closingOnFailure(channel)
        }
    }

    public func connect(to destination: Destination, context: DialContext) -> EventLoopFuture<any Channel> {
        dial(command: Self.commandTCP, destination: destination, packetMode: false, context: context)
    }

    public func openUDP(context: DialContext) -> EventLoopFuture<any OutboundUDPAssociation> {
        guard udpEnabled else {
            return context.eventLoop.makeFailedFuture(NetworkError(.netPolicyNoUDP, "\(name) has UDP relay disabled"))
        }
        let association = PerDestinationUDPAssociation(eventLoop: context.eventLoop) { destination in
            self.dial(command: Self.commandUDP, destination: destination, packetMode: true, context: context)
                .flatMapThrowing { channel in
                    try MessageUDPAssociation(channel: channel, source: destination) as any OutboundUDPAssociation
                }
        }
        return context.eventLoop.makeSucceededFuture(association)
    }
}

// MARK: - 数据块

/// 数据块的加密端：2 字节长度 ‖ 加密载荷 ‖ 标签（`none` 时为 2 字节长度 ‖ 明文）。
struct VMessChunkSealer {
    /// 每块明文上限（加上标签后长度字段不超过 16 KiB）。
    static let maxPayload = 16 * 1024 - AEADAlgorithm.tagLength

    private let algorithm: AEADAlgorithm?
    private let key: SymmetricKey
    private let iv: [UInt8]
    private var count: UInt16 = 0

    init(security: VMessSecurity, key: [UInt8], iv: [UInt8]) {
        self.iv = iv
        switch security {
        case .aes128GCM:
            algorithm = .aes128GCM
            self.key = SymmetricKey(data: key)
        case .chacha20Poly1305:
            algorithm = .chacha20Poly1305
            self.key = SymmetricKey(data: Self.chachaKey(key))
        case .none:
            algorithm = nil
            self.key = SymmetricKey(data: key)
        }
    }

    /// ChaCha20-Poly1305 的 32 字节密钥：MD5(key) ‖ MD5(MD5(key))。
    static func chachaKey(_ key: [UInt8]) -> [UInt8] {
        let first = Array(Insecure.MD5.hash(data: key))
        return first + Array(Insecure.MD5.hash(data: first))
    }

    /// 第 `count` 块的 nonce：2 字节大端计数 ‖ IV[2..<12]。
    static func nonce(count: UInt16, iv: [UInt8]) -> [UInt8] {
        [UInt8(count >> 8), UInt8(count & 0xFF)] + iv[2..<12]
    }

    mutating func seal(_ data: [UInt8], into output: inout ByteBuffer) throws {
        guard let algorithm else {
            output.writeInteger(UInt16(data.count))
            output.writeBytes(data)
            return
        }
        let sealed = try algorithm.seal(data, key: key, nonce: Self.nonce(count: count, iv: iv))
        count &+= 1
        output.writeInteger(UInt16(sealed.count))
        output.writeBytes(sealed)
    }
}

/// 数据块的解密端。内部只缓存不完整的块（≤ 64 KiB + 一次读取）。
struct VMessChunkOpener {
    private let algorithm: AEADAlgorithm?
    private let key: SymmetricKey
    private let iv: [UInt8]
    private var count: UInt16 = 0

    init(security: VMessSecurity, key: [UInt8], iv: [UInt8]) {
        self.iv = iv
        switch security {
        case .aes128GCM:
            algorithm = .aes128GCM
            self.key = SymmetricKey(data: key)
        case .chacha20Poly1305:
            algorithm = .chacha20Poly1305
            self.key = SymmetricKey(data: VMessChunkSealer.chachaKey(key))
        case .none:
            algorithm = nil
            self.key = SymmetricKey(data: key)
        }
    }

    /// 取出一个完整的块；数据不足返回 nil，认证失败抛出。空数组表示对端结束了该方向。
    mutating func next(_ buffer: inout ByteBuffer) throws -> [UInt8]? {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self),
            buffer.readableBytes >= 2 + Int(length)
        else { return nil }
        buffer.moveReaderIndex(forwardBy: 2)
        let body = buffer.readBytes(length: Int(length)) ?? []
        guard let algorithm else { return body }
        guard body.count >= AEADAlgorithm.tagLength,
            let plain = try? algorithm.open(body, key: key, nonce: VMessChunkSealer.nonce(count: count, iv: iv))
        else { throw NetworkError(.netProtocolError, "VMess chunk failed authentication") }
        count &+= 1
        return plain
    }
}

// MARK: - 管线

/// VMess 的管线编解码：加入时发送请求头；写入加密为数据块（包模式下每次写入一块）；
/// 输出方向关闭时发送空块（不关闭底层连接）；响应头在第一批数据到达时解密校验。
final class VMessStreamHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let session: VMessConnector.Session
    private let header: [UInt8]
    private let packetMode: Bool
    private var sealer: VMessChunkSealer
    private var opener: VMessChunkOpener
    private var pending = ByteBuffer()
    private var responseHeaderDone = false
    private var sentEnd = false
    private var receivedEnd = false
    private var failed = false

    init(session: VMessConnector.Session, header: [UInt8], packetMode: Bool) {
        self.session = session
        self.header = header
        self.packetMode = packetMode
        sealer = VMessChunkSealer(security: session.security, key: session.requestKey, iv: session.requestIV)
        opener = VMessChunkOpener(security: session.security, key: session.responseKey, iv: session.responseIV)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: header)), promise: nil)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var input = unwrapOutboundIn(data)
        guard !sentEnd else {
            promise?.fail(ChannelError.outputClosed)
            return
        }
        var output = context.channel.allocator.buffer(capacity: input.readableBytes + 64)
        do {
            if packetMode {
                try sealer.seal(input.readBytes(length: input.readableBytes) ?? [], into: &output)
            } else {
                repeat {
                    let chunk = input.readBytes(length: min(input.readableBytes, VMessChunkSealer.maxPayload)) ?? []
                    try sealer.seal(chunk, into: &output)
                } while input.readableBytes > 0
            }
        } catch {
            promise?.fail(error)
            fail(context: context, "VMess encryption failed: \(error)")
            return
        }
        context.write(wrapOutboundOut(output), promise: promise)
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        guard mode == .output else {
            context.close(mode: mode, promise: promise)
            return
        }
        // 半关闭：发送空块告诉服务端上行结束，底层连接保持，直到对端结束或完全关闭。
        if !sentEnd, context.channel.isActive {
            var output = context.channel.allocator.buffer(capacity: 32)
            if (try? sealer.seal([], into: &output)) != nil {
                context.writeAndFlush(wrapOutboundOut(output), promise: nil)
            }
        }
        sentEnd = true
        promise?.succeed(())
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed else { return }
        var input = unwrapInboundIn(data)
        pending.writeBuffer(&input)
        do {
            if !responseHeaderDone {
                guard try readResponseHeader() else { return }
                responseHeaderDone = true
            }
            var stream = context.channel.allocator.buffer(capacity: 0)
            while !receivedEnd, let chunk = try opener.next(&pending) {
                if chunk.isEmpty {
                    receivedEnd = true
                } else if packetMode {
                    context.fireChannelRead(wrapInboundOut(context.channel.allocator.buffer(bytes: chunk)))
                } else {
                    stream.writeBytes(chunk)
                }
            }
            pending.discardReadBytes()
            if stream.readableBytes > 0 {
                context.fireChannelRead(wrapInboundOut(stream))
            }
            if receivedEnd {
                context.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
                if sentEnd {
                    context.close(promise: nil)
                }
            }
        } catch {
            fail(context: context, "VMess response failed authentication (\(error))")
        }
    }

    /// 解密并校验 AEAD 响应头；数据不足返回 false。
    private func readResponseHeader() throws -> Bool {
        func key(_ label: String) -> SymmetricKey {
            SymmetricKey(data: VMessKDF.derive16(session.responseKey, path: [Array(label.utf8)]))
        }
        func iv(_ label: String) -> [UInt8] {
            Array(VMessKDF.derive(session.responseIV, path: [Array(label.utf8)]).prefix(12))
        }
        let tag = AEADAlgorithm.tagLength
        guard let sealedLength = pending.getBytes(at: pending.readerIndex, length: 2 + tag) else { return false }
        let lengthBytes = try AEADAlgorithm.aes128GCM.open(
            sealedLength, key: key("AEAD Resp Header Len Key"), nonce: iv("AEAD Resp Header Len IV"))
        guard lengthBytes.count == 2 else { throw NetworkError(.netProtocolError, "Malformed VMess response") }
        let length = Int(lengthBytes[0]) << 8 | Int(lengthBytes[1])
        guard let sealed = pending.getBytes(at: pending.readerIndex + 2 + tag, length: length + tag) else {
            return false
        }
        let header = try AEADAlgorithm.aes128GCM.open(
            sealed, key: key("AEAD Resp Header Key"), nonce: iv("AEAD Resp Header IV"))
        guard header.count >= 4, header[0] == session.responseAuth else {
            throw NetworkError(.netProtocolError, "VMess response authentication byte mismatch")
        }
        pending.moveReaderIndex(forwardBy: 2 + tag + length + tag)
        return true
    }

    private func fail(context: ChannelHandlerContext, _ message: String) {
        guard !failed else { return }
        failed = true
        context.fireErrorCaught(NetworkError(.netProtocolError, message))
        context.close(promise: nil)
    }
}

@available(*, unavailable)
extension VMessStreamHandler: Sendable {}

/// 消息式 Channel 上的 UDP 关联：每次读取是一个来自固定目标的数据报，每次发送写入一个数据报（VMess 包模式）。
/// Channel 不可写时新数据报丢弃并计数；Channel 关闭即关联结束。
final class MessageUDPAssociation: OutboundUDPAssociation, @unchecked Sendable {
    var onDatagram: ((ByteBuffer, Destination) -> Void)?
    var closeFuture: EventLoopFuture<Void> { closePromise.futureResult }
    private(set) var dropped = 0

    private let channel: any Channel
    private let source: Destination
    private let closePromise: EventLoopPromise<Void>
    private var closed = false

    init(channel: any Channel, source: Destination) throws {
        self.channel = channel
        self.source = source
        closePromise = channel.eventLoop.makePromise()
        try channel.pipeline.syncOperations.addHandler(MessageUDPReceiver(association: self))
        channel.closeFuture.whenComplete { _ in self.close() }
        ChannelTuning.startReading(channel)
    }

    func send(_ payload: ByteBuffer, to destination: Destination) {
        guard !closed, channel.isWritable, payload.readableBytes <= VMessChunkSealer.maxPayload else {
            dropped += 1
            return
        }
        channel.writeAndFlush(payload, promise: nil)
    }

    fileprivate func received(_ payload: ByteBuffer) {
        guard !closed else { return }
        onDatagram?(payload, source)
    }

    func close() {
        guard !closed else { return }
        closed = true
        onDatagram = nil
        channel.close(promise: nil)
        closePromise.succeed(())
    }
}

private final class MessageUDPReceiver: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private weak var association: MessageUDPAssociation?

    init(association: MessageUDPAssociation) {
        self.association = association
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        association?.received(unwrapInboundIn(data))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
