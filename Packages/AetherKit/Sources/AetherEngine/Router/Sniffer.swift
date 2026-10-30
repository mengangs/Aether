import AetherFoundation
import Foundation
import NIOCore

/// 嗅探结果（docs/06 §7）。
public enum SniffResult: Sendable, Equatable {
    /// 数据不足以判断。
    case needMoreData
    /// 不是可识别的协议。
    case unknown
    case tls(serverName: String?, alpn: [String])
    case http(host: String?)
}

/// TLS ClientHello 与 HTTP/1.x 请求头的嗅探（docs/06 §7）。纯函数，输入为已窥探到的字节。
public enum Sniffer {
    /// TLS 最多缓存 16 KiB，HTTP 最多 8 KiB。
    public static let tlsLimit = 16 * 1024
    public static let httpLimit = 8 * 1024
    /// 服务器先发数据的协议：跳过嗅探，避免引入 300 ms 等待。
    public static let skippedPorts: Set<UInt16> = [21, 22, 23, 25, 110, 143, 587, 3306, 5432, 6379]

    public static func sniff(_ bytes: [UInt8]) -> SniffResult {
        guard let first = bytes.first else { return .needMoreData }
        if first == 0x16 {
            return sniffTLS(bytes)
        }
        return sniffHTTP(bytes)
    }

    // MARK: TLS

    /// 解析 ClientHello 中的 SNI（server_name，类型 0）与 ALPN（16）。ClientHello 可能跨多个 TLS 记录。
    public static func sniffTLS(_ bytes: [UInt8]) -> SniffResult {
        // 把连续的握手类型记录（0x16）拼成握手消息流。
        var handshake: [UInt8] = []
        var offset = 0
        while offset + 5 <= bytes.count {
            guard bytes[offset] == 0x16, bytes[offset + 1] == 0x03 else {
                return handshake.isEmpty ? .unknown : parseClientHello(handshake) ?? .unknown
            }
            let length = Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])
            guard length > 0, length <= 16_384 + 256 else { return .unknown }
            let end = offset + 5 + length
            handshake.append(contentsOf: bytes[(offset + 5)..<min(end, bytes.count)])
            if let result = parseClientHello(handshake) {
                return result
            }
            guard end <= bytes.count else { break }
            offset = end
        }
        return bytes.count >= tlsLimit ? .unknown : .needMoreData
    }

    /// 握手消息完整时返回结果，不完整时返回 nil。
    static func parseClientHello(_ data: [UInt8]) -> SniffResult? {
        guard data.count >= 4 else { return nil }
        guard data[0] == 0x01 else { return .unknown }
        let length = Int(data[1]) << 16 | Int(data[2]) << 8 | Int(data[3])
        guard data.count >= 4 + length else { return nil }
        var reader = ByteReader(data[4..<(4 + length)])
        guard reader.skip(2 + 32),  // 版本、随机数
            let sessionLength = reader.uint8(), reader.skip(Int(sessionLength)),
            let cipherLength = reader.uint16(), reader.skip(Int(cipherLength)),
            let compressionLength = reader.uint8(), reader.skip(Int(compressionLength))
        else { return .unknown }
        guard let extensionsLength = reader.uint16() else { return .tls(serverName: nil, alpn: []) }
        var extensions = ByteReader(reader.bytes(Int(extensionsLength)) ?? [])
        var serverName: String?
        var alpn: [String] = []
        while let type = extensions.uint16(), let size = extensions.uint16(), let body = extensions.bytes(Int(size)) {
            var item = ByteReader(body[...])
            switch type {
            case 0x0000:
                _ = item.uint16()
                while let nameType = item.uint8(), let nameLength = item.uint16(),
                    let name = item.bytes(Int(nameLength))
                {
                    if nameType == 0, serverName == nil {
                        serverName = String(decoding: name, as: UTF8.self)
                    }
                }
            case 0x0010:
                _ = item.uint16()
                while let protocolLength = item.uint8(), let name = item.bytes(Int(protocolLength)) {
                    alpn.append(String(decoding: name, as: UTF8.self))
                }
            default:
                break
            }
        }
        return .tls(serverName: serverName, alpn: alpn)
    }

    // MARK: HTTP

    static let methods: [String] = [
        "GET ", "POST ", "HEAD ", "PUT ", "DELETE ", "OPTIONS ", "PATCH ", "CONNECT ", "TRACE ",
    ]

    /// 解析 HTTP/1.x 请求行与 `Host` 头。
    public static func sniffHTTP(_ bytes: [UInt8]) -> SniffResult {
        let prefix = String(decoding: bytes.prefix(8), as: UTF8.self)
        let couldBeMethod = methods.contains { $0.hasPrefix(prefix) || prefix.hasPrefix($0) }
        guard couldBeMethod else { return .unknown }
        guard let headerEnd = find([13, 10, 13, 10], in: bytes) else {
            return bytes.count >= httpLimit ? .unknown : .needMoreData
        }
        let text = String(decoding: bytes[..<headerEnd], as: UTF8.self)
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first, requestLine.contains(" HTTP/1.") else { return .unknown }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == "host" {
                var host = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if host.hasPrefix("[") {
                    host = String(host.dropFirst().prefix { $0 != "]" })
                } else if let portColon = host.lastIndex(of: ":") {
                    host = String(host[..<portColon])
                }
                return .http(host: host.isEmpty ? nil : host)
            }
        }
        return .http(host: nil)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard haystack.count >= needle.count else { return nil }
        for index in 0...(haystack.count - needle.count) where haystack[index] == needle[0] {
            if Array(haystack[index..<(index + needle.count)]) == needle {
                return index
            }
        }
        return nil
    }
}

/// 简单的大端读取器。
struct ByteReader {
    private var data: ArraySlice<UInt8>

    init(_ data: ArraySlice<UInt8>) {
        self.data = data
    }

    init(_ data: [UInt8]) {
        self.data = data[...]
    }

    mutating func uint8() -> UInt8? {
        guard let value = data.first else { return nil }
        data = data.dropFirst()
        return value
    }

    mutating func uint16() -> UInt16? {
        guard data.count >= 2 else { return nil }
        let value = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
        data = data.dropFirst(2)
        return value
    }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, data.count >= count else { return nil }
        let value = Array(data.prefix(count))
        data = data.dropFirst(count)
        return value
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, data.count >= count else { return false }
        data = data.dropFirst(count)
        return true
    }
}

/// 窥探 TCP 流的首包（docs/06 §7）：读到能判断协议、达到上限、读到 EOF 或超过 300 ms 时结束，
/// 交出窥探到的字节（出站建立后原样首先写出）与结果，然后移除自己并停止读取。
final class SniffHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private var buffer: ByteBuffer
    private let promise: EventLoopPromise<(bytes: ByteBuffer, result: SniffResult)>
    private let timeout: TimeAmount
    private var timer: Scheduled<Void>?
    private var finished = false

    init(initial: ByteBuffer?, timeout: TimeAmount, promise: EventLoopPromise<(bytes: ByteBuffer, result: SniffResult)>)
    {
        buffer = initial ?? ByteBuffer()
        self.timeout = timeout
        self.promise = promise
    }

    func handlerAdded(context: ChannelHandlerContext) {
        if buffer.readableBytes > 0, evaluate(context: context) {
            return
        }
        let loopBound = NIOLoopBound((self, context), eventLoop: context.eventLoop)
        timer = context.eventLoop.scheduleTask(in: timeout) {
            let (handler, context) = loopBound.value
            handler.finish(context: context, result: .unknown)
        }
        try? context.channel.syncOptions?.setOption(.autoRead, value: true)
        context.read()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else {
            context.fireChannelRead(data)
            return
        }
        var incoming = unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        _ = evaluate(context: context)
    }

    /// 返回是否已结束。
    private func evaluate(context: ChannelHandlerContext) -> Bool {
        let result = Sniffer.sniff(Array(buffer.readableBytesView))
        if result != .needMoreData {
            finish(context: context, result: result)
            return true
        }
        if buffer.readableBytes >= Sniffer.tlsLimit {
            finish(context: context, result: .unknown)
            return true
        }
        return false
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent, !finished {
            finish(context: context, result: .unknown)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished {
            finished = true
            timer?.cancel()
            promise.fail(NetworkError(.netConnectionReset, "Client closed before the first bytes"))
        }
        context.fireChannelInactive()
    }

    private func finish(context: ChannelHandlerContext, result: SniffResult) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        try? context.channel.syncOptions?.setOption(.autoRead, value: false)
        let bytes = buffer
        buffer = ByteBuffer()
        context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
        promise.succeed((bytes, result))
    }
}

@available(*, unavailable)
extension SniffHandler: Sendable {}
