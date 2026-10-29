/// 地址块（IP-CIDR / IP-CIDR6 规则、路由、skip-proxy 等）。网络地址按前缀规范化（主机位清零）。
public struct CIDR: Hashable, Sendable, CustomStringConvertible {
    public let network: IPAddress
    public let prefixLength: Int

    /// - Returns: 前缀超出范围（v4 0–32，v6 0–128）时为 nil。
    public init?(network: IPAddress, prefixLength: Int) {
        switch network {
        case .v4(let v4):
            guard (0...32).contains(prefixLength) else { return nil }
            self.network = .v4(IPv4Address(v4.value & Self.mask32(prefixLength)))
        case .v6(let v6):
            guard (0...128).contains(prefixLength) else { return nil }
            let (h, l) = Self.mask128(prefixLength)
            self.network = .v6(IPv6Address(high: v6.high & h, low: v6.low & l))
        }
        self.prefixLength = prefixLength
    }

    /// 解析 `地址/前缀`；省略前缀时视为单个地址（/32 或 /128）。
    public init?(_ text: some StringProtocol) {
        let string = String(text)
        let parts = string.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = IPAddress(parts[0]) else { return nil }
        let length: Int
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy({ $0.isASCII && $0.isNumber }), parts[1].count <= 3,
                let value = Int(parts[1])
            else { return nil }
            length = value
        } else {
            length = address.isIPv4 ? 32 : 128
        }
        self.init(network: address, prefixLength: length)
    }

    public var description: String { "\(network)/\(prefixLength)" }

    /// 是否包含该地址。IPv4 块也包含对应的 IPv4 映射 IPv6 地址。
    public func contains(_ address: IPAddress) -> Bool {
        switch (network, address.unmappedIPv4) {
        case (.v4(let net), .v4(let v4)):
            return v4.value & Self.mask32(prefixLength) == net.value
        case (.v6(let net), .v6(let v6)):
            let (h, l) = Self.mask128(prefixLength)
            return v6.high & h == net.high && v6.low & l == net.low
        default:
            return false
        }
    }

    /// 块内第一个与最后一个地址。
    public var range: ClosedRange<IPAddress> {
        switch network {
        case .v4(let net):
            let last = net.value | ~Self.mask32(prefixLength)
            return network...IPAddress.v4(IPv4Address(last))
        case .v6(let net):
            let (h, l) = Self.mask128(prefixLength)
            return network...IPAddress.v6(IPv6Address(high: net.high | ~h, low: net.low | ~l))
        }
    }

    /// IPv4 前缀对应的点分掩码（如 /15 → 255.254.0.0）；IPv6 时为 nil。
    public var ipv4SubnetMask: IPv4Address? {
        guard network.isIPv4 else { return nil }
        return IPv4Address(Self.mask32(prefixLength))
    }

    static func mask32(_ length: Int) -> UInt32 {
        length == 0 ? 0 : UInt32.max << (32 - length)
    }

    static func mask128(_ length: Int) -> (UInt64, UInt64) {
        if length == 0 { return (0, 0) }
        if length <= 64 { return (UInt64.max << (64 - length), 0) }
        if length == 128 { return (.max, .max) }
        return (.max, UInt64.max << (128 - length))
    }
}
