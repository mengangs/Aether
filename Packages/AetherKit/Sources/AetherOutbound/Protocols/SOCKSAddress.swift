import AetherFoundation
import NIOCore

/// SOCKS5 地址格式（RFC 1928 §5）：`ATYP` + 地址 + 2 字节端口。SOCKS5、Shadowsocks、Trojan 共用。
public enum SOCKSAddress {
    public static let typeIPv4: UInt8 = 0x01
    public static let typeDomain: UInt8 = 0x03
    public static let typeIPv6: UInt8 = 0x04

    public enum ParseResult: Equatable {
        /// 数据不足，等待更多字节。
        case needMoreData
        /// 地址类型不支持（SOCKS5 回复码 0x08）。
        case unsupportedType(UInt8)
        /// 域名无效（空、含控制字符等）。
        case invalidDomain
        /// 解析成功，`length` 为地址部分（含 ATYP 与端口）的字节数。
        case parsed(Destination, length: Int)
    }

    /// 从 `buffer` 的 `offset`（相对 readerIndex）处解析，不移动读指针。
    public static func parse(_ buffer: ByteBuffer, at offset: Int = 0) -> ParseResult {
        let base = buffer.readerIndex + offset
        guard let type = buffer.getInteger(at: base, as: UInt8.self) else { return .needMoreData }
        switch type {
        case typeIPv4:
            guard let bytes = buffer.getBytes(at: base + 1, length: 4),
                let port = buffer.getInteger(at: base + 5, as: UInt16.self),
                let v4 = IPv4Address(bytes: bytes)
            else { return .needMoreData }
            return .parsed(.ip(.v4(v4), port: port), length: 7)
        case typeIPv6:
            guard let bytes = buffer.getBytes(at: base + 1, length: 16),
                let port = buffer.getInteger(at: base + 17, as: UInt16.self),
                let v6 = IPv6Address(bytes: bytes)
            else { return .needMoreData }
            return .parsed(.ip(IPAddress.v6(v6).unmappedIPv4, port: port), length: 19)
        case typeDomain:
            guard let length = buffer.getInteger(at: base + 1, as: UInt8.self) else { return .needMoreData }
            guard let name = buffer.getString(at: base + 2, length: Int(length)),
                let port = buffer.getInteger(at: base + 2 + Int(length), as: UInt16.self)
            else { return .needMoreData }
            guard length > 0, let destination = Destination(host: name, port: port) else { return .invalidDomain }
            return .parsed(destination, length: 4 + Int(length))
        default:
            return .unsupportedType(type)
        }
    }

    /// 编码目标地址。域名超过 255 字节时截断不会发生：`Hostname` 上限 253。
    public static func write(_ destination: Destination, to buffer: inout ByteBuffer) {
        switch destination {
        case .ip(.v4(let v4), let port):
            buffer.writeInteger(typeIPv4)
            buffer.writeInteger(v4.value)
            buffer.writeInteger(port)
        case .ip(.v6(let v6), let port):
            buffer.writeInteger(typeIPv6)
            buffer.writeInteger(v6.high)
            buffer.writeInteger(v6.low)
            buffer.writeInteger(port)
        case .domain(let host, let port):
            let name = Array(host.value.utf8.prefix(255))
            buffer.writeInteger(typeDomain)
            buffer.writeInteger(UInt8(name.count))
            buffer.writeBytes(name)
            buffer.writeInteger(port)
        }
    }

    /// 编码后的长度。
    public static func length(of destination: Destination) -> Int {
        switch destination {
        case .ip(.v4, _): return 7
        case .ip(.v6, _): return 19
        case .domain(let host, _): return 4 + min(host.value.utf8.count, 255)
        }
    }
}
