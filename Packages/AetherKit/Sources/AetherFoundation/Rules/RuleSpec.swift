/// 规则（docs/04 §7）。逻辑规则递归持有子规则；子规则与规则集内规则没有策略。
public struct RuleSpec: Sendable, Equatable {
    public var condition: RuleCondition
    /// 策略名；子规则与规则集内规则为 nil。
    public var policy: String?
    public var options: RuleOptions
    /// 原文（去首尾空白）。
    public var raw: String
    public var source: SourceReference

    public init(
        condition: RuleCondition, policy: String?, options: RuleOptions = RuleOptions(), raw: String,
        source: SourceReference
    ) {
        self.condition = condition
        self.policy = policy
        self.options = options
        self.raw = raw
        self.source = source
    }

    /// 规则是否在 iOS 上生效（不支持的类型解析保留但不生效，`CFG-031`）。
    public var isEffective: Bool { condition.isEffective }
}

/// 规则选项（docs/04 §7.4）。
public struct RuleOptions: Sendable, Equatable {
    public var noResolve = false
    public var updateInterval: Double?
    public var dnsFailed = false

    public init(noResolve: Bool = false, updateInterval: Double? = nil, dnsFailed: Bool = false) {
        self.noResolve = noResolve
        self.updateInterval = updateInterval
        self.dnsFailed = dnsFailed
    }
}

/// `PROTOCOL` 规则的值。
public enum RuleProtocol: String, Sendable, Equatable, CaseIterable {
    case tcp = "TCP"
    case udp = "UDP"
    case http = "HTTP"
    case https = "HTTPS"
    case quic = "QUIC"
}

/// `HOSTNAME-TYPE` 规则的值。
public enum HostnameType: String, Sendable, Equatable, CaseIterable {
    case ipv4 = "IPV4"
    case ipv6 = "IPV6"
    case domain = "DOMAIN"
    case simple = "SIMPLE"
}

/// `SUBNET` 规则的值（docs/04 §7.2）。
public enum SubnetCondition: Sendable, Equatable {
    case ssid(String)
    case bssid(String)
    case interfaceType(InterfaceType)

    public enum InterfaceType: String, Sendable, Equatable, CaseIterable {
        case wifi = "WIFI"
        case cellular = "CELLULAR"
        case wired = "WIRED"
    }
}

/// 规则条件。
public indirect enum RuleCondition: Sendable, Equatable {
    case domain(Hostname)
    case domainSuffix(Hostname)
    /// 小写子串。
    case domainKeyword(String)
    /// 小写通配模式。
    case domainWildcard(String)
    case domainSet(String)
    /// URL、本地路径或内置 `LAN`。
    case ruleSet(String)
    case ipCIDR(CIDR)
    case ipCIDR6(CIDR)
    /// 大写 ISO 3166 国家代码。
    case geoIP(String)
    case ipASN(UInt32)
    case destPort(ClosedRange<UInt16>)
    case inPort(ClosedRange<UInt16>)
    case `protocol`(RuleProtocol)
    case hostnameType(HostnameType)
    case subnet(SubnetCondition)
    /// 通配模式。
    case userAgent(String)
    /// ICU 正则。
    case urlRegex(String)
    case and([RuleSpec])
    case or([RuleSpec])
    case not(RuleSpec)
    case final
    /// 识别但在 iOS 上不支持或尚未实现（`PROCESS-NAME`、`SCRIPT` 等），解析保留、不生效。
    case unsupported(type: String, value: String)

    /// 规则类型名（大写）。
    public var typeName: String {
        switch self {
        case .domain: return "DOMAIN"
        case .domainSuffix: return "DOMAIN-SUFFIX"
        case .domainKeyword: return "DOMAIN-KEYWORD"
        case .domainWildcard: return "DOMAIN-WILDCARD"
        case .domainSet: return "DOMAIN-SET"
        case .ruleSet: return "RULE-SET"
        case .ipCIDR: return "IP-CIDR"
        case .ipCIDR6: return "IP-CIDR6"
        case .geoIP: return "GEOIP"
        case .ipASN: return "IP-ASN"
        case .destPort: return "DEST-PORT"
        case .inPort: return "IN-PORT"
        case .protocol: return "PROTOCOL"
        case .hostnameType: return "HOSTNAME-TYPE"
        case .subnet: return "SUBNET"
        case .userAgent: return "USER-AGENT"
        case .urlRegex: return "URL-REGEX"
        case .and: return "AND"
        case .or: return "OR"
        case .not: return "NOT"
        case .final: return "FINAL"
        case .unsupported(let type, _): return type
        }
    }

    public var isEffective: Bool {
        switch self {
        case .unsupported: return false
        case .and(let children), .or(let children): return children.allSatisfy(\.isEffective)
        case .not(let child): return child.isEffective
        default: return true
        }
    }

    /// 是否需要目标 IP（docs/05 §3.4）。
    public var requiresIP: Bool {
        switch self {
        case .ipCIDR, .ipCIDR6, .geoIP, .ipASN: return true
        case .and(let children), .or(let children): return children.contains { $0.condition.requiresIP }
        case .not(let child): return child.condition.requiresIP
        default: return false
        }
    }
}
