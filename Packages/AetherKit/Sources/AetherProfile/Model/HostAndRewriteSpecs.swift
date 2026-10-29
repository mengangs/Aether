import AetherFoundation

/// `[Host]` 条目（docs/04 §8）。
public struct HostSpec: Sendable, Equatable {
    public enum Value: Sendable, Equatable {
        case addresses([IPAddress])
        case alias(Hostname)
        /// `server:IP[:端口]` / `server:system` / `server:https://…` / `server:tls://…`
        case server(String)
        /// `server:script:<名>`（M7）。
        case script(String)
    }

    /// 域名或通配模式（小写）。
    public var pattern: String
    public var isWildcard: Bool { pattern.contains("*") || pattern.contains("?") }
    public var value: Value
    public var source: SourceReference

    public init(pattern: String, value: Value, source: SourceReference) {
        self.pattern = pattern
        self.value = value
        self.source = source
    }
}

/// `[URL Rewrite]` 条目（docs/04 §9.1）。
public struct URLRewriteSpec: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable, CaseIterable {
        case found = "302"
        case temporaryRedirect = "307"
        case header
        case reject
        case reject200 = "reject-200"
        case rejectImage = "reject-img"
        case rejectDict = "reject-dict"
        case rejectArray = "reject-array"
        case rejectDrop = "reject-drop"
    }

    public var pattern: String
    public var replacement: String
    public var action: Action
    public var source: SourceReference
}

/// `[Header Rewrite]` 条目（docs/04 §9.2）。
public struct HeaderRewriteSpec: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case request = "http-request"
        case response = "http-response"
    }

    public enum Operation: Sendable, Equatable {
        case add(name: String, value: String)
        case delete(name: String)
        case replace(name: String, value: String)
        case replaceRegex(name: String, pattern: String, replacement: String)
    }

    public var phase: Phase
    public var pattern: String
    public var operation: Operation
    public var source: SourceReference
}

/// `[Body Rewrite]` 条目（docs/04 §9.3）。
public struct BodyRewriteSpec: Sendable, Equatable {
    public var phase: HeaderRewriteSpec.Phase
    public var urlPattern: String
    public var replacements: [(pattern: String, replacement: String)]
    public var source: SourceReference

    public static func == (lhs: BodyRewriteSpec, rhs: BodyRewriteSpec) -> Bool {
        lhs.phase == rhs.phase && lhs.urlPattern == rhs.urlPattern && lhs.source == rhs.source
            && lhs.replacements.map(\.pattern) == rhs.replacements.map(\.pattern)
            && lhs.replacements.map(\.replacement) == rhs.replacements.map(\.replacement)
    }
}

/// `[Map Local]` 条目（docs/04 §9.4）。
public struct MapLocalSpec: Sendable, Equatable {
    public enum DataType: String, Sendable, Equatable, CaseIterable {
        case text
        case json
        case base64
        case file
        case tinyGIF = "tiny-gif"
    }

    public var urlPattern: String
    public var dataType: DataType
    public var data: String
    public var statusCode: Int
    public var headers: [HTTPHeaderField]
    public var source: SourceReference
}

/// `[Script]` 条目（docs/04 §10）。
public struct ScriptSpec: Sendable, Equatable {
    public enum ScriptType: String, Sendable, Equatable, CaseIterable {
        case httpRequest = "http-request"
        case httpResponse = "http-response"
        case cron
        case event
        case generic
        /// M7。
        case dns
        /// M7。
        case rule
    }

    public var name: String
    public var type: ScriptType
    public var scriptPath: String
    public var updateInterval = 86400.0
    public var timeout = 10.0
    public var argument = ""
    public var debug = false
    public var pattern: String?
    public var requiresBody = false
    public var maxSize = 131_072
    public var binaryBodyMode = false
    public var cronExpression: CronExpression?
    public var eventName: String?
    public var source: SourceReference

    /// v1.0 是否执行该脚本（`dns`、`rule` 类型在 M7）。
    public var isSupported: Bool { type != .dns && type != .rule }

    public init(name: String, type: ScriptType, scriptPath: String, source: SourceReference) {
        self.name = name
        self.type = type
        self.scriptPath = scriptPath
        self.source = source
    }
}

/// `[MITM]` 节（docs/04 §11）。
public struct MITMSpec: Sendable, Equatable {
    public struct HostnamePattern: Sendable, Equatable, Hashable {
        /// 小写通配模式；`*` 表示全部主机。
        public var host: String
        /// nil 表示默认 443。
        public var port: UInt16?
        public var isExclusion: Bool

        public init(host: String, port: UInt16?, isExclusion: Bool) {
            self.host = host
            self.port = port
            self.isExclusion = isExclusion
        }
    }

    public var hostnames: [HostnamePattern] = []
    public var skipServerCertVerify = false
    public var autoQUICBlock = true
    public var h2 = false
    /// 仅用于导入。
    public var caP12: String?
    public var caPassphrase: String?

    public init() {}
}

/// 需要下载的外部资源（docs/04 §15.1、docs/11 §5）。
public struct ExternalResourceRef: Sendable, Equatable, Hashable {
    public enum Kind: String, Sendable, Equatable, Hashable {
        case ruleSet = "rule-set"
        case domainSet = "domain-set"
        case policyPath = "policy-path"
        case script
        case geoIPDatabase = "geoip-db"
        case ipASNDatabase = "ipasn-db"
        case mapLocalFile = "map-local"
        case managedProfile = "managed-profile"
    }

    public var url: String
    public var kind: Kind
    /// 秒；nil 表示使用 `resource-update-interval`。
    public var updateInterval: Double?
    public var source: SourceReference

    public init(url: String, kind: Kind, updateInterval: Double?, source: SourceReference) {
        self.url = url
        self.kind = kind
        self.updateInterval = updateInterval
        self.source = source
    }

    /// 是否为远程 URL（否则为本地路径）。
    public var isRemote: Bool { url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") }
}
