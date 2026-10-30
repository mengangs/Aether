/// utun 的包格式（docs/06 §4.1 备用桥接）：每个 IP 包前有 4 字节、网络字节序的协议族（Darwin 的 `AF_INET` = 2、
/// `AF_INET6` = 30）。备用桥接在 `NEPacketTunnelFlow` 与交给 hev 的 socket 之间搬运时加上或去掉这个头。
public enum UTunFraming {
    /// Darwin 的协议族值（与运行平台无关，utun 格式固定使用它们）。
    public static let familyIPv4: UInt32 = 2
    public static let familyIPv6: UInt32 = 30

    /// 按 IP 版本号（首字节高 4 位）得到协议族；不是 IPv4 / IPv6 时为 nil。
    public static func family(ofPacket packet: some Collection<UInt8>) -> UInt32? {
        guard let first = packet.first else { return nil }
        switch first >> 4 {
        case 4: return familyIPv4
        case 6: return familyIPv6
        default: return nil
        }
    }

    /// 给 IP 包加上 utun 头；`family` 为 nil 时按 IP 版本号推断，无法推断时为 nil（丢弃）。
    public static func wrap(_ packet: [UInt8], family: UInt32? = nil) -> [UInt8]? {
        guard let family = family ?? self.family(ofPacket: packet) else { return nil }
        var frame: [UInt8] = []
        frame.reserveCapacity(packet.count + 4)
        frame.append(UInt8(truncatingIfNeeded: family >> 24))
        frame.append(UInt8(truncatingIfNeeded: family >> 16))
        frame.append(UInt8(truncatingIfNeeded: family >> 8))
        frame.append(UInt8(truncatingIfNeeded: family))
        frame.append(contentsOf: packet)
        return frame
    }

    /// 去掉 utun 头，得到 IP 包与协议族；不足 4 字节、协议族未知或为空包时为 nil（丢弃）。
    public static func unwrap(_ frame: [UInt8]) -> (packet: [UInt8], family: UInt32)? {
        guard frame.count > 4 else { return nil }
        let family = frame[0..<4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard family == familyIPv4 || family == familyIPv6 else { return nil }
        return (Array(frame[4...]), family)
    }
}
