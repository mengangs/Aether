// 规则词汇类型的 Codable 实现，供规则集编译缓存（docs/05 §6.4）使用。

extension Hostname: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let host = Hostname(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid host \(text)"))
        }
        self = host
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension CIDR: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let cidr = CIDR(text) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid CIDR \(text)"))
        }
        self = cidr
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension RuleProtocol: Codable {}
extension HostnameType: Codable {}
extension SubnetCondition.InterfaceType: Codable {}
