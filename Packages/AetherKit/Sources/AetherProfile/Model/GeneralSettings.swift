import AetherFoundation

/// `[General]` 的类型化结果（docs/04 §4）。未出现的键取默认值。
public struct GeneralSettings: Sendable, Equatable {
    public enum DNSMode: String, Sendable, Equatable {
        case fakeIP = "fake-ip"
        case realIP = "real-ip"
    }

    public enum BlockQUIC: String, Sendable, Equatable {
        case auto
        case always
        case never
    }

    public var logLevel = "notice"
    public var dnsServers = ["system"]
    public var encryptedDNSServers: [String] = []
    public var encryptedDNSSkipCertVerify = false
    public var dnsMode = DNSMode.fakeIP
    public var fakeIPRange = CIDR(ipv4: IPv4Address(198, 18, 0, 0), prefixLength: 15)
    /// 为空表示使用内置默认表（docs/07 §3.3）。
    public var alwaysRealIP: [String]?
    public var hijackDNS = ["*:53"]
    public var ipv6 = false
    public var skipProxy = GeneralSettings.defaultSkipProxy
    public var excludeSimpleHostnames = true
    public var systemProxy = true
    public var tunIncludedRoutes: [CIDR] = []
    public var tunExcludedRoutes: [CIDR] = []
    public var tunMTU = 1500
    public var sniffing = true
    public var blockQUIC = BlockQUIC.auto
    /// `DIRECT` 或 `REJECT`。
    public var udpPolicyNotSupportedBehaviour = "REJECT"
    public var internetTestURL = "http://www.apple.com/library/test/success.html"
    public var proxyTestURL = "http://www.gstatic.com/generate_204"
    public var testTimeout = 5.0
    public var geoIPDatabaseURL: String?
    public var ipASNDatabaseURL: String?
    public var resourceUpdateInterval = 86400.0
    public var resourceFetchPolicy = "DIRECT"
    public var showErrorPageForReject = false
    public var httpAPI: String?
    public var httpAPITLS = false
    public var allowWiFiAccess = false
    public var wifiAccessHTTPPort = 6171
    public var wifiAccessSOCKS5Port = 6172

    public static let defaultSkipProxy = [
        "127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "169.254.0.0/16",
        "localhost", "*.local",
    ]

    public init() {}
}
