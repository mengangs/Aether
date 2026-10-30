import AetherFoundation
import Foundation
import NIOCore

/// VLESS（xtls.github.io VLESS 协议文档，docs/06 §8.4），只支持 `flow` 为空、在 TLS 或 WS + TLS 之上使用：
///
/// - 请求：版本 0 ‖ 16 字节 UUID ‖ 附加信息长度 0 ‖ 命令（1 TCP、2 UDP）‖ 2 字节端口 ‖ 地址类型（1 IPv4、2 域名、
///   3 IPv6）‖ 地址；连接后立即发送。
/// - 响应：版本 ‖ 附加信息长度 ‖ 附加信息，之后为原始数据。服务端通常随第一批数据一起发送响应头，
///   因此由 `VLESSResponseHandler` 在数据到达时剥掉，不阻塞连接的返回。
/// - UDP：每个目标一条连接（命令 2），数据报为 2 字节长度 ‖ 载荷（`PerDestinationUDPAssociation`）。
public struct VLESSConnector: OutboundConnector {
    public let name: String
    public let server: ProxyServer
    public let udpEnabled: Bool
    let uuid: [UInt8]

    public var capabilities: OutboundCapabilities {
        udpEnabled ? [.tcp, .udp, .remoteResolve] : [.tcp, .remoteResolve]
    }

    /// `uuid` 无法解析时返回 nil。
    public init?(name: String, server: ProxyServer, uuid: String, udpEnabled: Bool) {
        guard let parsed = UUID(uuidString: uuid) else { return nil }
        self.name = name
        self.server = server
        self.udpEnabled = udpEnabled
        self.uuid = withUnsafeBytes(of: parsed.uuid) { Array($0) }
    }

    static let commandTCP: UInt8 = 0x01
    static let commandUDP: UInt8 = 0x02

    /// 请求头。
    static func header(uuid: [UInt8], command: UInt8, destination: Destination, into buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt8(0))
        buffer.writeBytes(uuid)
        buffer.writeInteger(UInt8(0))
        buffer.writeInteger(command)
        PortFirstAddress.write(destination, to: &buffer)
    }

    private func dial(command: UInt8, destination: Destination, context: DialContext) -> EventLoopFuture<any Channel> {
        let uuid = self.uuid
        return server.dial(context: context).flatMap { channel in
            channel.eventLoop.makeCompletedFuture { () -> any Channel in
                try channel.pipeline.syncOperations.addHandler(VLESSResponseHandler())
                var header = channel.allocator.buffer(capacity: 22 + SOCKSAddress.length(of: destination))
                Self.header(uuid: uuid, command: command, destination: destination, into: &header)
                channel.writeAndFlush(header, promise: nil)
                return channel
            }.closingOnFailure(channel)
        }
    }

    public func connect(to destination: Destination, context: DialContext) -> EventLoopFuture<any Channel> {
        dial(command: Self.commandTCP, destination: destination, context: context)
    }

    public func openUDP(context: DialContext) -> EventLoopFuture<any OutboundUDPAssociation> {
        guard udpEnabled else {
            return context.eventLoop.makeFailedFuture(NetworkError(.netPolicyNoUDP, "\(name) has UDP relay disabled"))
        }
        let association = PerDestinationUDPAssociation(eventLoop: context.eventLoop) { destination in
            self.dial(command: Self.commandUDP, destination: destination, context: context).flatMapThrowing {
                channel in
                try StreamUDPAssociation(channel: channel, framing: LengthPrefixedFraming(destination: destination))
                    as any OutboundUDPAssociation
            }
        }
        return context.eventLoop.makeSucceededFuture(association)
    }
}

/// 剥掉 VLESS 响应头（版本 ‖ 附加信息长度 ‖ 附加信息）后移除自己。版本不为 0 时以 `NET-032` 关闭。
final class VLESSResponseHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private var buffer = ByteBuffer()
    private var done = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !done else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        guard let version = buffer.getInteger(at: buffer.readerIndex, as: UInt8.self),
            let addons = buffer.getInteger(at: buffer.readerIndex + 1, as: UInt8.self)
        else { return }
        guard version == 0 else {
            done = true
            context.fireErrorCaught(NetworkError(.netProtocolError, "Unexpected VLESS response version \(version)"))
            context.close(promise: nil)
            return
        }
        guard buffer.readableBytes >= 2 + Int(addons) else { return }
        buffer.moveReaderIndex(forwardBy: 2 + Int(addons))
        let rest = buffer
        buffer = ByteBuffer()
        done = true
        // 先交出响应头之后的数据再移除自己：从已移除的 context 发出的事件不会到达后面的 Handler。
        if rest.readableBytes > 0 {
            context.fireChannelRead(wrapInboundOut(rest))
        }
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
    }
}

@available(*, unavailable)
extension VLESSResponseHandler: Sendable {}

/// 固定目标的数据报帧：2 字节大端长度 ‖ 载荷（VLESS UDP）。
struct LengthPrefixedFraming: StreamPacketFraming {
    let destination: Destination

    func encode(_ payload: ByteBuffer, to destination: Destination, into buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt16(payload.readableBytes))
        var payload = payload
        buffer.writeBuffer(&payload)
    }

    func decode(_ buffer: inout ByteBuffer) throws -> (payload: ByteBuffer, source: Destination)? {
        guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self),
            buffer.readableBytes >= 2 + Int(length)
        else { return nil }
        buffer.moveReaderIndex(forwardBy: 2)
        guard let payload = buffer.readSlice(length: Int(length)) else { return nil }
        return (payload, destination)
    }
}
