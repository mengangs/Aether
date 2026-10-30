import AetherFoundation

/// 规则匹配的输入（docs/05 §2）。字段由引擎填写；规则引擎不得自行发起 DNS 或读取系统状态。
public struct RouteContext: Sendable, Equatable {
    public enum HostSource: String, Sendable, Equatable {
        case request
        case fakeIP
        case dnsReverse
        case sniffed
        case none
    }

    public enum Transport: String, Sendable, Equatable {
        case tcp
        case udp
    }

    public enum AppProtocol: String, Sendable, Equatable {
        case unknown
        case http
        case https
        case quic
    }

    public enum InboundKind: Sendable, Equatable {
        case tun
        case httpProxy
        case socks
        case script(String)
    }

    /// 规范化域名；只有 IP 时为 nil。
    public var host: Hostname?
    public var hostSource: HostSource
    public var destinationIP: IPAddress?
    public var destinationPort: UInt16
    public var transport: Transport
    public var appProtocol: AppProtocol
    public var inbound: InboundKind
    public var inboundPort: UInt16?
    /// 仅明文 HTTP 或 MitM 后可见。
    public var url: String?
    public var userAgent: String?
    public var network: NetworkSnapshot
    /// 引擎在解析失败后置位。
    public var resolutionFailed: Bool

    public init(
        host: Hostname? = nil, hostSource: HostSource = .none, destinationIP: IPAddress? = nil, destinationPort: UInt16,
        transport: Transport = .tcp, appProtocol: AppProtocol = .unknown, inbound: InboundKind = .tun,
        inboundPort: UInt16? = nil, url: String? = nil, userAgent: String? = nil,
        network: NetworkSnapshot = NetworkSnapshot(),
        resolutionFailed: Bool = false
    ) {
        self.host = host
        self.hostSource = hostSource
        self.destinationIP = destinationIP
        self.destinationPort = destinationPort
        self.transport = transport
        self.appProtocol = appProtocol
        self.inbound = inbound
        self.inboundPort = inboundPort
        self.url = url
        self.userAgent = userAgent
        self.network = network
        self.resolutionFailed = resolutionFailed
    }
}

/// 当前网络环境（SUBNET 规则使用）。
public struct NetworkSnapshot: Sendable, Equatable, Hashable {
    public var interfaceType: SubnetCondition.InterfaceType?
    /// 缺少 wifi-info 能力或不在 Wi-Fi 下时为 nil。
    public var ssid: String?
    public var bssid: String?
    /// 网络环境修订号，每次变化加一（决策缓存键的一部分）。
    public var revision: Int
    /// 是否有可用网络（`NWPath.status == .satisfied`）。
    public var isSatisfied: Bool
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool
    /// 昂贵（蜂窝、个人热点）。
    public var isExpensive: Bool
    /// 受限（低数据模式）。
    public var isConstrained: Bool

    public init(
        interfaceType: SubnetCondition.InterfaceType? = nil, ssid: String? = nil, bssid: String? = nil,
        revision: Int = 0, isSatisfied: Bool = true, supportsIPv4: Bool = true, supportsIPv6: Bool = false,
        isExpensive: Bool = false, isConstrained: Bool = false
    ) {
        self.interfaceType = interfaceType
        self.ssid = ssid
        self.bssid = bssid
        self.revision = revision
        self.isSatisfied = isSatisfied
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    /// 是否与 `other` 属于不同的网络环境（接口类型、SSID、IPv4 / IPv6 可用性之一变化，docs/06 §11）。
    public func differsInEnvironment(from other: NetworkSnapshot) -> Bool {
        interfaceType != other.interfaceType || ssid != other.ssid || supportsIPv4 != other.supportsIPv4
            || supportsIPv6 != other.supportsIPv6
    }
}

/// 规则集（编译后）。集内规则不带策略，任一命中即命中。
public protocol RuleSetMatching: Sendable {
    /// 集内规则条数（追踪中展示）。
    var ruleCount: Int { get }
    /// - Parameter noResolve: 引用处的 `no-resolve`，作用于集内全部 IP 类规则。
    func match(_ context: RouteContext, noResolve: Bool) -> RuleOutcome
    /// 集内是否含依赖 URL / User-Agent 的规则（影响决策缓存）。
    var dependsOnRequestDetails: Bool { get }
}

/// GeoIP / ASN 查询（MMDB 读取器在 M3-10 实现）。
public protocol IPMetadataLookup: Sendable {
    /// ISO 3166 国家代码（大写）。
    func country(for address: IPAddress) -> String?
    func asn(for address: IPAddress) -> UInt32?
}

/// 规则编译时提供已加载的外部内容（docs/05 §1）。未加载的资源返回 nil，引用它的规则视为不可判定。
public protocol RuleResourceProvider: Sendable {
    func ruleSet(_ location: String) -> (any RuleSetMatching)?
    func domainSet(_ location: String) -> ReversedDomainTable?
    var geoIP: (any IPMetadataLookup)? { get }
    var ipASN: (any IPMetadataLookup)? { get }
}

/// 不提供任何外部资源（只有内置 `LAN`）。
public struct EmptyRuleResources: RuleResourceProvider {
    public init() {}
    public func ruleSet(_ location: String) -> (any RuleSetMatching)? { nil }
    public func domainSet(_ location: String) -> ReversedDomainTable? { nil }
    public var geoIP: (any IPMetadataLookup)? { nil }
    public var ipASN: (any IPMetadataLookup)? { nil }
}

/// 平台能力（docs/05 §1）：声明哪些规则类型在当前平台不可用（视为不可判定）。
public struct PlatformCapabilities: Sendable {
    public var unavailableRuleTypes: Set<String>

    public init(unavailableRuleTypes: Set<String> = []) {
        self.unavailableRuleTypes = unavailableRuleTypes
    }

    public static let iOS = PlatformCapabilities()
}

/// 单条规则的判定结果（docs/05 §3.2）。
public enum RuleOutcome: Sendable, Equatable {
    case match
    case noMatch
    /// 需要目标 IP 才能判定（上下文只有域名，规则未带 no-resolve）。
    case needsIP
    /// 依赖的信息不可得（如未解密 HTTPS 的 URL、未加载的数据库、iOS 不支持的类型），视为不命中。
    case undecidable(String)
}
