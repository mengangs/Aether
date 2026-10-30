import AetherFoundation
import NIOCore

/// Trojan（trojan-gfw 协议文档，docs/06 §8.4）：TLS（或 WS + TLS）之上发送
/// `hex(SHA224(password))` CRLF 命令 地址 CRLF，之后为原始数据。服务端没有应答，密码错误时服务端关闭连接
/// 或按回落配置转发，因此连接本身不能判断凭据是否正确。
///
/// - TCP：连接后立即发送请求头（服务端先说话的协议也能工作）。
/// - UDP：一个关联一条 TLS 连接，命令 3；请求头随第一个数据报发出（地址取该数据报的目标）。
///   数据报格式为 地址 ‖ 2 字节长度 ‖ CRLF ‖ 载荷。
public struct TrojanConnector: OutboundConnector {
    public let name: String
    public let server: ProxyServer
    public let udpEnabled: Bool
    /// `hex(SHA224(password))` 的 ASCII。
    let passwordHash: [UInt8]

    public var capabilities: OutboundCapabilities {
        udpEnabled ? [.tcp, .udp, .remoteResolve] : [.tcp, .remoteResolve]
    }

    /// `server.tls` 为 nil 时使用默认 TLS 参数（Trojan 总是在 TLS 之上）。
    public init(name: String, server: ProxyServer, password: String, udpEnabled: Bool) {
        var server = server
        if server.tls == nil {
            server.tls = TLSClientOptions()
        }
        self.name = name
        self.server = server
        self.udpEnabled = udpEnabled
        passwordHash = Array(SHA224.hash(Array(password.utf8)).map { byte in Self.hexDigits(byte) }.joined().utf8)
    }

    private static func hexDigits(_ byte: UInt8) -> String {
        let digits = Array("0123456789abcdef")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }

    static let commandConnect: UInt8 = 0x01
    static let commandUDPAssociate: UInt8 = 0x03

    /// 请求头。
    static func header(passwordHash: [UInt8], command: UInt8, destination: Destination, into buffer: inout ByteBuffer) {
        buffer.writeBytes(passwordHash)
        buffer.writeBytes([13, 10, command])
        SOCKSAddress.write(destination, to: &buffer)
        buffer.writeBytes([13, 10])
    }

    public func connect(to destination: Destination, context: DialContext) -> EventLoopFuture<any Channel> {
        let passwordHash = self.passwordHash
        return server.dial(context: context).flatMap { channel in
            var header = channel.allocator.buffer(
                capacity: passwordHash.count + 6 + SOCKSAddress.length(of: destination))
            Self.header(
                passwordHash: passwordHash, command: Self.commandConnect, destination: destination, into: &header)
            channel.writeAndFlush(header, promise: nil)
            return channel.eventLoop.makeSucceededFuture(channel)
        }
    }

    public func openUDP(context: DialContext) -> EventLoopFuture<any OutboundUDPAssociation> {
        guard udpEnabled else {
            return context.eventLoop.makeFailedFuture(NetworkError(.netPolicyNoUDP, "\(name) has UDP relay disabled"))
        }
        let passwordHash = self.passwordHash
        return server.dial(context: context).flatMapThrowing { channel in
            try StreamUDPAssociation(channel: channel, framing: TrojanUDPFraming(passwordHash: passwordHash))
        }
    }
}

/// Trojan 的 UDP 数据报帧：地址 ‖ 2 字节长度 ‖ CRLF ‖ 载荷；第一个数据报之前加请求头。
struct TrojanUDPFraming: StreamPacketFraming {
    let passwordHash: [UInt8]
    private var sentHeader = false

    init(passwordHash: [UInt8]) {
        self.passwordHash = passwordHash
    }

    /// 之后的数据报不再加请求头（服务端方向的编码、测试）。
    mutating func markHeaderSent() {
        sentHeader = true
    }

    mutating func encode(_ payload: ByteBuffer, to destination: Destination, into buffer: inout ByteBuffer) {
        if !sentHeader {
            sentHeader = true
            TrojanConnector.header(
                passwordHash: passwordHash, command: TrojanConnector.commandUDPAssociate, destination: destination,
                into: &buffer)
        }
        SOCKSAddress.write(destination, to: &buffer)
        buffer.writeInteger(UInt16(payload.readableBytes))
        buffer.writeBytes([13, 10])
        var payload = payload
        buffer.writeBuffer(&payload)
    }

    mutating func decode(_ buffer: inout ByteBuffer) throws -> (payload: ByteBuffer, source: Destination)? {
        switch SOCKSAddress.parse(buffer) {
        case .needMoreData:
            return nil
        case .unsupportedType, .invalidDomain:
            throw NetworkError(.netProtocolError, "Malformed Trojan UDP packet")
        case .parsed(let source, let length):
            guard let size = buffer.getInteger(at: buffer.readerIndex + length, as: UInt16.self),
                buffer.readableBytes >= length + 4 + Int(size)
            else { return nil }
            guard buffer.getInteger(at: buffer.readerIndex + length + 2, as: UInt16.self) == 0x0D0A else {
                throw NetworkError(.netProtocolError, "Malformed Trojan UDP packet")
            }
            buffer.moveReaderIndex(forwardBy: length + 4)
            guard let payload = buffer.readSlice(length: Int(size)) else { return nil }
            return (payload, source)
        }
    }
}
