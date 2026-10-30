import AetherFoundation
import Foundation
import NIOCore

/// simple-obfs tls（docs/06 §8.5，按 simple-obfs `obfs_tls.c` 的报文布局）：
///
/// - 第一次写入伪装成 TLS 1.2 ClientHello：随机数与会话 ID 随机，固定的密码套件与扩展列表；数据放在紧跟
///   ClientHello 固定部分的 session ticket 扩展中（服务端只认这个位置），其后是 SNI（`obfs-host` 或服务器地址）
///   与其余扩展。第一次写入超过 `maxTicketBytes` 的部分以应用数据记录发送。
/// - 之后的写入封装为应用数据记录（`17 03 03` + 长度），每条最多 16 KiB。
/// - 收到的数据按 TLS 记录解析：ServerHello 与 ChangeCipherSpec 跳过；ChangeCipherSpec 之后的握手记录
///   （伪装的 Finished，服务端把第一批数据放在其中）与应用数据记录的内容交出；记录长度超过 16 KiB + 2 KiB
///   或类型未知时以 `NET-032` 关闭。缓冲最多一条记录。
final class SimpleObfsTLSHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let maxRecordPayload = 16 * 1024
    static let maxTicketBytes = 8 * 1024
    static let maxIncomingRecord = 16 * 1024 + 2048

    private let host: String
    private var sentHello = false
    private var sawChangeCipherSpec = false
    private var pending = ByteBuffer()
    private var failed = false

    init(host: String) {
        self.host = host
    }

    /// simple-obfs 的固定密码套件（28 个，56 字节）。
    static let cipherSuites: [UInt8] = [
        0xc0, 0x2c, 0xc0, 0x30, 0x00, 0x9f, 0xcc, 0xa9, 0xcc, 0xa8, 0xcc, 0xaa, 0xc0, 0x2b, 0xc0, 0x2f,
        0x00, 0x9e, 0xc0, 0x24, 0xc0, 0x28, 0x00, 0x6b, 0xc0, 0x23, 0xc0, 0x27, 0x00, 0x67, 0xc0, 0x0a,
        0xc0, 0x14, 0x00, 0x39, 0xc0, 0x09, 0xc0, 0x13, 0x00, 0x33, 0x00, 0x9d, 0x00, 0x9c, 0x00, 0x3d,
        0x00, 0x3c, 0x00, 0x35, 0x00, 0x2f, 0x00, 0xff,
    ]

    /// SNI 之后的固定扩展：ec_point_formats、supported_groups、signature_algorithms、encrypt_then_mac、
    /// extended_master_secret。
    static let otherExtensions: [UInt8] = [
        0x00, 0x0b, 0x00, 0x04, 0x03, 0x01, 0x00, 0x02,
        0x00, 0x0a, 0x00, 0x0a, 0x00, 0x08, 0x00, 0x1d, 0x00, 0x17, 0x00, 0x19, 0x00, 0x18,
        0x00, 0x0d, 0x00, 0x20, 0x00, 0x1e,
        0x06, 0x01, 0x06, 0x02, 0x06, 0x03, 0x05, 0x01, 0x05, 0x02, 0x05, 0x03, 0x04, 0x01, 0x04, 0x02,
        0x04, 0x03, 0x03, 0x01, 0x03, 0x02, 0x03, 0x03, 0x02, 0x01, 0x02, 0x02, 0x02, 0x03,
        0x00, 0x16, 0x00, 0x00,
        0x00, 0x17, 0x00, 0x00,
    ]

    /// ClientHello 记录，`ticket` 为 session ticket 扩展的内容。
    static func clientHello(ticket: [UInt8], host: String, random: [UInt8], sessionID: [UInt8]) -> ByteBuffer {
        let name = Array(host.utf8.prefix(255))
        var extensions = ByteBuffer()
        extensions.writeBytes([0x00, 0x23])
        extensions.writeInteger(UInt16(ticket.count))
        extensions.writeBytes(ticket)
        extensions.writeBytes([0x00, 0x00])
        extensions.writeInteger(UInt16(name.count + 5))
        extensions.writeInteger(UInt16(name.count + 3))
        extensions.writeInteger(UInt8(0))
        extensions.writeInteger(UInt16(name.count))
        extensions.writeBytes(name)
        extensions.writeBytes(otherExtensions)

        var body = ByteBuffer()
        body.writeBytes([0x03, 0x03])
        body.writeBytes(random)
        body.writeInteger(UInt8(sessionID.count))
        body.writeBytes(sessionID)
        body.writeInteger(UInt16(cipherSuites.count))
        body.writeBytes(cipherSuites)
        body.writeBytes([0x01, 0x00])
        body.writeInteger(UInt16(extensions.readableBytes))
        body.writeBuffer(&extensions)

        var record = ByteBuffer()
        record.writeBytes([0x16, 0x03, 0x01])
        record.writeInteger(UInt16(body.readableBytes + 4))
        record.writeInteger(UInt8(0x01))
        record.writeInteger(UInt8(0))
        record.writeInteger(UInt16(body.readableBytes))
        record.writeBuffer(&body)
        return record
    }

    /// 把 `data` 封装为应用数据记录追加到 `output`。
    static func appendApplicationData(_ data: inout ByteBuffer, to output: inout ByteBuffer) {
        while data.readableBytes > 0 {
            let count = min(data.readableBytes, maxRecordPayload)
            output.writeBytes([0x17, 0x03, 0x03])
            output.writeInteger(UInt16(count))
            if var slice = data.readSlice(length: count) {
                output.writeBuffer(&slice)
            }
        }
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var input = unwrapOutboundIn(data)
        var output = context.channel.allocator.buffer(capacity: input.readableBytes + 256)
        if !sentHello {
            sentHello = true
            let ticket = input.readBytes(length: min(input.readableBytes, Self.maxTicketBytes)) ?? []
            let seconds = UInt32(truncatingIfNeeded: Int(Date().timeIntervalSince1970))
            var random: [UInt8] = [
                UInt8(seconds >> 24), UInt8(truncatingIfNeeded: seconds >> 16),
                UInt8(truncatingIfNeeded: seconds >> 8), UInt8(truncatingIfNeeded: seconds),
            ]
            random += ShadowsocksConnector.randomSalt(28)
            var hello = Self.clientHello(
                ticket: ticket, host: host, random: random, sessionID: ShadowsocksConnector.randomSalt(32))
            output.writeBuffer(&hello)
        }
        Self.appendApplicationData(&input, to: &output)
        context.write(wrapOutboundOut(output), promise: promise)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !failed else { return }
        var incoming = unwrapInboundIn(data)
        pending.writeBuffer(&incoming)
        var output = context.channel.allocator.buffer(capacity: 0)
        while let type = pending.getInteger(at: pending.readerIndex, as: UInt8.self),
            let length = pending.getInteger(at: pending.readerIndex + 3, as: UInt16.self)
        {
            guard Int(length) <= Self.maxIncomingRecord, [0x14, 0x16, 0x17].contains(type) else {
                failed = true
                context.fireErrorCaught(NetworkError(.netProtocolError, "simple-obfs tls: unexpected record"))
                context.close(promise: nil)
                return
            }
            guard pending.readableBytes >= 5 + Int(length) else { break }
            pending.moveReaderIndex(forwardBy: 5)
            let carriesData = type == 0x17 || (type == 0x16 && sawChangeCipherSpec)
            if type == 0x14 {
                sawChangeCipherSpec = true
            }
            if carriesData, var payload = pending.readSlice(length: Int(length)) {
                output.writeBuffer(&payload)
            } else {
                pending.moveReaderIndex(forwardBy: Int(length))
            }
        }
        pending.discardReadBytes()
        if output.readableBytes > 0 {
            context.fireChannelRead(wrapInboundOut(output))
        }
    }
}

@available(*, unavailable)
extension SimpleObfsTLSHandler: Sendable {}
