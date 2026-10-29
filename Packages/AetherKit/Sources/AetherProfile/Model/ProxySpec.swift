import AetherFoundation

/// 内置策略（docs/04 §5.1）。
public enum BuiltinPolicy: String, Sendable, Equatable, CaseIterable {
    case direct = "DIRECT"
    case reject = "REJECT"
    case rejectDrop = "REJECT-DROP"
    case rejectNoDrop = "REJECT-NO-DROP"
    case rejectTinyGIF = "REJECT-TINYGIF"

    /// 不区分大小写匹配内置策略名。
    public init?(name: String) {
        self.init(rawValue: name.uppercased())
    }

    /// `[Proxy]` 中别名类型（`direct`、`reject` …）。
    init?(aliasType: String) {
        switch aliasType.lowercased() {
        case "direct": self = .direct
        case "reject": self = .reject
        case "reject-drop": self = .rejectDrop
        case "reject-no-drop": self = .rejectNoDrop
        case "reject-tinygif": self = .rejectTinyGIF
        default: return nil
        }
    }
}

/// TLS 参数（docs/04 §5.3）。
public struct TLSOptions: Sendable, Equatable {
    public enum SNI: Sendable, Equatable {
        /// 使用服务器域名。
        case server
        case custom(String)
        /// `sni=off`：不发送 SNI。
        case disabled
    }

    public var sni = SNI.server
    public var skipCertVerify = false
    /// `server-cert-fingerprint-sha256`，32 字节。
    public var certificateFingerprintSHA256: [UInt8]?
    public var alpn: [String] = []

    public init() {}
}

/// WebSocket 参数（docs/04 §5.4）。
public struct WebSocketOptions: Sendable, Equatable {
    public var path = "/"
    public var headers: [HTTPHeaderField] = []

    public init() {}
}

/// 一个 HTTP 头字段（保留顺序与大小写）。
public struct HTTPHeaderField: Sendable, Equatable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Shadowsocks 加密方式（docs/04 §5.5）。
public enum ShadowsocksMethod: String, Sendable, Equatable, CaseIterable {
    case aes128GCM = "aes-128-gcm"
    case aes256GCM = "aes-256-gcm"
    case chacha20IETFPoly1305 = "chacha20-ietf-poly1305"
    case blake3AES128GCM = "2022-blake3-aes-128-gcm"
    case blake3AES256GCM = "2022-blake3-aes-256-gcm"
    case blake3ChaCha20Poly1305 = "2022-blake3-chacha20-poly1305"

    public var is2022: Bool { rawValue.hasPrefix("2022-") }

    /// 已不安全、不支持的流加密（`CFG-023`）。
    static let insecureStreamCiphers: Set<String> = [
        "rc4", "rc4-md5", "rc4-md5-6", "aes-128-cfb", "aes-192-cfb", "aes-256-cfb", "aes-128-ctr", "aes-192-ctr",
        "aes-256-ctr", "aes-128-ofb", "aes-192-ofb", "aes-256-ofb", "camellia-128-cfb", "camellia-192-cfb",
        "camellia-256-cfb", "bf-cfb", "cast5-cfb", "des-cfb", "idea-cfb", "rc2-cfb", "seed-cfb", "salsa20", "chacha20",
        "chacha20-ietf", "xchacha20", "table", "none", "plain",
    ]
}

/// VMess 加密方式。
public enum VMessCipher: String, Sendable, Equatable, CaseIterable {
    case auto
    case aes128GCM = "aes-128-gcm"
    case chacha20Poly1305 = "chacha20-poly1305"
    case none
}

/// 节点的协议相关部分。
public enum ProxyProtocol: Sendable, Equatable {
    /// `[Proxy]` 中的内置策略别名（如 `国内 = direct`）。
    case alias(BuiltinPolicy)
    /// `http` / `https`（`tls != nil`）。
    case http(username: String?, password: String?, alwaysUseConnect: Bool)
    /// `socks5` / `socks5-tls`（`tls != nil`）。
    case socks5(username: String?, password: String?)
    case shadowsocks(method: ShadowsocksMethod, password: String, obfs: SimpleObfs?)
    case trojan(password: String)
    case vmess(uuid: String, cipher: VMessCipher)
    case vless(uuid: String)
    /// 识别但不可用的类型（`CFG-022`）或变体（`CFG-023`）。
    case unavailable(type: String)
}

/// simple-obfs 插件参数。
public struct SimpleObfs: Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        case http
        case tls
    }

    public var mode: Mode
    public var host: String?
    public var uri: String?

    public init(mode: Mode, host: String?, uri: String?) {
        self.mode = mode
        self.host = host
        self.uri = uri
    }
}

/// 解析服务器地址时的地址族策略（docs/04 §5.2）。
public enum IPVersionPreference: String, Sendable, Equatable {
    case dual
    case v4Only = "v4-only"
    case v6Only = "v6-only"
    case preferV4 = "prefer-v4"
    case preferV6 = "prefer-v6"
}

/// `[Proxy]` 条目（docs/04 §5）。
public struct ProxySpec: Sendable, Equatable {
    public var name: String
    /// 配置中写的类型（小写原文），如 `https`、`ss`。
    public var type: String
    public var server: String?
    public var port: UInt16?
    public var proxyProtocol: ProxyProtocol
    public var tls: TLSOptions?
    public var webSocket: WebSocketOptions?
    public var udpRelay = false
    public var testURL: String?
    public var testTimeout: Double?
    public var ipVersion = IPVersionPreference.dual
    /// 覆盖全局 `block-quic`：`auto` / `on` / `off`。
    public var blockQUIC: String?
    public var underlyingProxy: String?
    public var source: SourceReference

    /// 节点是否可用（不支持的类型或变体不可用，但保留在配置中）。
    public var isUsable: Bool {
        if case .unavailable = proxyProtocol { return false }
        return true
    }

    public init(name: String, type: String, proxyProtocol: ProxyProtocol, source: SourceReference) {
        self.name = name
        self.type = type
        self.proxyProtocol = proxyProtocol
        self.source = source
    }
}
