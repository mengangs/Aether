import AetherDNS
import AetherFoundation
import AetherOutbound
import AetherProfile
import AetherRules
import NIOCore

/// 代理节点的运行时形态。
public struct ProxyNode: Sendable {
    public var name: String
    /// 配置中写的类型（如 `https`、`socks5`）。
    public var type: String
    /// 不可用（不支持的类型、M3 之前的协议）时为 nil，选中它的流以 `NET-020` 失败。
    public var connector: (any OutboundConnector)?
    public var unavailableReason: String?
    public var supportsUDP: Bool
    /// 节点身份：类型 + 服务器 + 端口 + 凭据哈希（测速结果按它迁移，docs/06 §14）。
    public var identity: String
    /// 节点的 `block-quic`（`auto` / `on` / `off`）；为 nil 时用全局设置。
    public var blockQUIC: String?
    /// 节点的 `test-url` / `test-timeout`（秒）；为 nil 时用组或全局设置。
    public var testURL: String? = nil
    public var testTimeout: Double? = nil
}

/// 策略组的运行时形态。
public struct PolicyGroup: Sendable {
    public var name: String
    public var type: PolicyGroupSpec.GroupType
    /// 解析后的成员（显式成员、`include-all-proxies`、`include-other-group`），按配置顺序去重。
    public var members: [String]
    public var hidden: Bool
    /// 自动组的测速参数（docs/04 §6.2）：`url` 为 nil 时用 `proxy-test-url`，`timeout` 为 nil 时用 `test-timeout`。
    public var testURL: String? = nil
    public var interval: Double = 600
    public var timeout: Double? = nil
    /// 毫秒。
    public var tolerance: Int = 50
    public var evaluateBeforeUse = false
    public var persistent = false
}

/// 运行时策略。
public enum RuntimePolicy: Sendable {
    case direct
    case reject(RejectKind)
    case proxy(ProxyNode)
    case group(PolicyGroup)

    public var isGroup: Bool {
        if case .group = self { return true }
        return false
    }

    public var isReject: Bool {
        if case .reject = self { return true }
        return false
    }
}

/// 隧道在控制面编译的运行配置（docs/06 §14）：不可变值，新流读取当前引用，已有流持有旧引用直到结束。
public final class RuntimeConfiguration: Sendable {
    public let revision: String
    public let profileID: String
    public let profileName: String
    public let general: GeneralSettings
    public let program: RuleProgram
    public let policies: [String: RuntimePolicy]
    /// 策略组名，按配置顺序。
    public let groupOrder: [String]
    /// 节点名，按配置顺序。
    public let proxyOrder: [String]
    public let dns: DNSConfiguration
    /// `hijack-dns`：被劫持交给 DNS 服务的目标（`*:53`、`IP:端口`）。
    public let hijackDNS: [(address: IPAddress?, port: UInt16)]
    /// 编译时的提示（不可用的节点、M3 之后才支持的功能等），写入日志簿。
    public let notes: [String]

    init(
        revision: String, profileID: String, profileName: String, general: GeneralSettings, program: RuleProgram,
        policies: [String: RuntimePolicy], groupOrder: [String], proxyOrder: [String], dns: DNSConfiguration,
        hijackDNS: [(address: IPAddress?, port: UInt16)], notes: [String]
    ) {
        self.revision = revision
        self.profileID = profileID
        self.profileName = profileName
        self.general = general
        self.program = program
        self.policies = policies
        self.groupOrder = groupOrder
        self.proxyOrder = proxyOrder
        self.dns = dns
        self.hijackDNS = hijackDNS
        self.notes = notes
    }

    /// 由已叠加模块、已校验的配置编译。`resources` 提供已缓存的规则集与域名集（缺失的视为不可判定）。
    public static func compile(
        _ resolved: ResolvedProfile, profileID: String = "", profileName: String = "",
        resources: some RuleResourceProvider = EmptyRuleResources()
    ) -> RuntimeConfiguration {
        var notes: [String] = []
        var policies: [String: RuntimePolicy] = [
            "DIRECT": .direct, "REJECT": .reject(.reject), "REJECT-DROP": .reject(.drop),
            "REJECT-NO-DROP": .reject(.noDrop), "REJECT-TINYGIF": .reject(.tinyGIF),
        ]
        var proxyOrder: [String] = []
        for spec in resolved.proxies {
            var policy = makePolicy(spec, notes: &notes)
            if case .proxy(var node) = policy {
                node.testURL = spec.testURL
                node.testTimeout = spec.testTimeout
                policy = .proxy(node)
            }
            policies[spec.name] = policy
            proxyOrder.append(spec.name)
        }
        var groupOrder: [String] = []
        for group in resolved.groups {
            var members: [String] = []
            var seen = Set<String>()
            func add(_ name: String) {
                if seen.insert(name).inserted { members.append(name) }
            }
            group.members.forEach(add)
            if group.includeAllProxies {
                proxyOrder.forEach(add)
            }
            group.includeOtherGroups.forEach(add)
            if group.policyPath != nil {
                notes.append(
                    "Group \(group.name): policy-path subscriptions are loaded from M3; members from it are absent")
            }
            var runtimeGroup = PolicyGroup(name: group.name, type: group.type, members: members, hidden: group.hidden)
            runtimeGroup.testURL = group.url
            runtimeGroup.interval = group.interval
            runtimeGroup.timeout = group.timeout
            runtimeGroup.tolerance = group.tolerance
            runtimeGroup.evaluateBeforeUse = group.evaluateBeforeUse
            runtimeGroup.persistent = group.persistent
            policies[group.name] = .group(runtimeGroup)
            groupOrder.append(group.name)
        }
        let program = RuleProgram.compile(resolved.rules, resources: resources)
        return RuntimeConfiguration(
            revision: resolved.revision, profileID: profileID, profileName: profileName, general: resolved.general,
            program: program, policies: policies, groupOrder: groupOrder, proxyOrder: proxyOrder,
            dns: dnsConfiguration(resolved), hijackDNS: parseHijack(resolved.general.hijackDNS), notes: notes)
    }

    static func makePolicy(_ spec: ProxySpec, notes: inout [String]) -> RuntimePolicy {
        if case .alias(let builtin) = spec.proxyProtocol {
            switch builtin {
            case .direct: return .direct
            case .reject: return .reject(.reject)
            case .rejectDrop: return .reject(.drop)
            case .rejectNoDrop: return .reject(.noDrop)
            case .rejectTinyGIF: return .reject(.tinyGIF)
            }
        }
        let identity = nodeIdentity(spec)
        guard spec.isUsable, let host = spec.server, let port = spec.port else {
            return unavailable(spec, identity: identity, reason: "\(spec.type) is not supported", notes: &notes)
        }
        let server = ProxyServer(
            host: host, port: port,
            addressPreference: AddressFamilyPreference(rawValue: spec.ipVersion.rawValue) ?? .dual,
            tls: spec.tls.map(tlsOptions))
        switch spec.proxyProtocol {
        case .http(let username, let password, _):
            let connector = HTTPConnectConnector(
                name: spec.name, server: server, username: username, password: password)
            return .proxy(
                ProxyNode(
                    name: spec.name, type: spec.type, connector: connector, unavailableReason: nil, supportsUDP: false,
                    identity: identity, blockQUIC: spec.blockQUIC))
        case .socks5(let username, let password):
            let connector = SOCKS5Connector(
                name: spec.name, server: server, username: username, password: password, udpEnabled: spec.udpRelay)
            return .proxy(
                ProxyNode(
                    name: spec.name, type: spec.type, connector: connector, unavailableReason: nil,
                    supportsUDP: spec.udpRelay, identity: identity, blockQUIC: spec.blockQUIC))
        case .shadowsocks(let method, let password, let obfs):
            let obfsOptions = obfs.map {
                SimpleObfsOptions(mode: $0.mode == .tls ? .tls : .http, host: $0.host, uri: $0.uri ?? "/")
            }
            let ssServer = ProxyServer(host: host, port: port, addressPreference: server.addressPreference)
            let connector: (any OutboundConnector)?
            var supportsUDP = spec.udpRelay
            if let aead = ShadowsocksAEADMethod(rawValue: method.rawValue) {
                connector = ShadowsocksConnector(
                    name: spec.name, server: ssServer, method: aead, password: password, obfs: obfsOptions,
                    udpEnabled: spec.udpRelay)
            } else if let method2022 = Shadowsocks2022Method(rawValue: method.rawValue) {
                connector = Shadowsocks2022Connector(
                    name: spec.name, server: ssServer, method: method2022, password: password, obfs: obfsOptions,
                    udpEnabled: spec.udpRelay)
                if spec.udpRelay, !method2022.supportsUDP {
                    supportsUDP = false
                    notes.append(
                        "Proxy \(spec.name): \(method.rawValue) relays TCP only until M7 (UDP needs XChaCha20)")
                }
            } else {
                connector = nil
            }
            guard let connector else {
                return unavailable(
                    spec, identity: identity, reason: "Invalid password or method for \(method.rawValue)",
                    notes: &notes)
            }
            return .proxy(
                ProxyNode(
                    name: spec.name, type: spec.type, connector: connector, unavailableReason: nil,
                    supportsUDP: supportsUDP, identity: identity, blockQUIC: spec.blockQUIC))
        case .trojan(let password):
            let connector = TrojanConnector(
                name: spec.name,
                server: ProxyServer(
                    host: host, port: port, addressPreference: server.addressPreference,
                    tls: server.tls ?? TLSClientOptions(), webSocket: spec.webSocket.map(webSocketOptions)),
                password: password, udpEnabled: spec.udpRelay)
            return .proxy(
                ProxyNode(
                    name: spec.name, type: spec.type, connector: connector, unavailableReason: nil,
                    supportsUDP: spec.udpRelay, identity: identity, blockQUIC: spec.blockQUIC))
        case .vless(let uuid):
            guard let tls = server.tls else {
                return unavailable(
                    spec, identity: identity, reason: "VLESS requires tls=true (06 §8.4)", notes: &notes)
            }
            guard
                let connector = VLESSConnector(
                    name: spec.name,
                    server: ProxyServer(
                        host: host, port: port, addressPreference: server.addressPreference, tls: tls,
                        webSocket: spec.webSocket.map(webSocketOptions)),
                    uuid: uuid, udpEnabled: spec.udpRelay)
            else {
                return unavailable(spec, identity: identity, reason: "Invalid VLESS UUID", notes: &notes)
            }
            return .proxy(
                ProxyNode(
                    name: spec.name, type: spec.type, connector: connector, unavailableReason: nil,
                    supportsUDP: spec.udpRelay, identity: identity, blockQUIC: spec.blockQUIC))
        case .vmess(let uuid, let cipher):
            let security: VMessSecurity
            switch cipher {
            case .auto, .aes128GCM: security = .aes128GCM
            case .chacha20Poly1305: security = .chacha20Poly1305
            case .none: security = .none
            }
            guard
                let connector = VMessConnector(
                    name: spec.name,
                    server: ProxyServer(
                        host: host, port: port, addressPreference: server.addressPreference, tls: server.tls,
                        webSocket: spec.webSocket.map(webSocketOptions)),
                    uuid: uuid, security: security, udpEnabled: spec.udpRelay)
            else {
                return unavailable(spec, identity: identity, reason: "Invalid VMess UUID", notes: &notes)
            }
            return .proxy(
                ProxyNode(
                    name: spec.name, type: spec.type, connector: connector, unavailableReason: nil,
                    supportsUDP: spec.udpRelay, identity: identity, blockQUIC: spec.blockQUIC))
        default:
            notes.append("Proxy \(spec.name): \(spec.type) is supported from M3")
            return .proxy(
                ProxyNode(
                    name: spec.name, type: spec.type, connector: nil, unavailableReason: "\(spec.type) arrives in M3",
                    supportsUDP: false, identity: identity, blockQUIC: spec.blockQUIC))
        }
    }

    /// 本里程碑尚未实现的协议变体：节点不可用并写入提示。
    static func unavailable(_ spec: ProxySpec, identity: String, reason: String, notes: inout [String]) -> RuntimePolicy
    {
        notes.append("Proxy \(spec.name): \(reason)")
        return .proxy(
            ProxyNode(
                name: spec.name, type: spec.type, connector: nil, unavailableReason: reason, supportsUDP: false,
                identity: identity, blockQUIC: spec.blockQUIC))
    }

    static func webSocketOptions(_ options: WebSocketOptions) -> WebSocketClientOptions {
        WebSocketClientOptions(
            path: options.path, headers: options.headers.map { .init(name: $0.name, value: $0.value) })
    }

    static func tlsOptions(_ options: TLSOptions) -> TLSClientOptions {
        var result = TLSClientOptions()
        switch options.sni {
        case .server: result.serverName = .server
        case .custom(let name): result.serverName = .custom(name)
        case .disabled: result.serverName = .disabled
        }
        result.skipCertificateVerification = options.skipCertVerify
        result.certificateFingerprintSHA256 = options.certificateFingerprintSHA256
        result.alpn = options.alpn
        return result
    }

    /// 类型 + 服务器 + 端口 + 凭据的 FNV-1a 哈希（只用于比较身份，不可逆推凭据）。
    static func nodeIdentity(_ spec: ProxySpec) -> String {
        var credentials = ""
        switch spec.proxyProtocol {
        case .http(let user, let password, _), .socks5(let user, let password):
            credentials = "\(user ?? ""):\(password ?? "")"
        case .shadowsocks(let method, let password, _): credentials = "\(method.rawValue):\(password)"
        case .trojan(let password): credentials = password
        case .vmess(let uuid, let cipher): credentials = "\(uuid):\(cipher.rawValue)"
        case .vless(let uuid): credentials = uuid
        case .alias, .unavailable: break
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in credentials.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return "\(spec.type)|\(spec.server ?? "")|\(spec.port ?? 0)|\(String(hash, radix: 16))"
    }

    static func dnsConfiguration(_ resolved: ResolvedProfile) -> DNSConfiguration {
        let general = resolved.general
        var configuration = DNSConfiguration()
        configuration.mode = general.dnsMode == .fakeIP ? .fakeIP : .realIP
        configuration.fakeIPRange = general.fakeIPRange
        // ipv6 = true 在 M7 之前按 false 处理（docs/07 §3.4，CFG-099）。
        configuration.ipv6 = false
        configuration.alwaysRealIP = general.alwaysRealIP
        configuration.servers = general.dnsServers
        configuration.encryptedServers = general.encryptedDNSServers
        configuration.hosts = resolved.hosts.compactMap { host -> HostEntry? in
            switch host.value {
            case .addresses(let addresses): return HostEntry(pattern: host.pattern, value: .addresses(addresses))
            case .alias(let target): return HostEntry(pattern: host.pattern, value: .alias(target.value))
            case .server(let server): return HostEntry(pattern: host.pattern, value: .upstream(server))
            case .script: return nil
            }
        }
        return configuration
    }

    /// `hijack-dns` 的条目：`*:53`（任意地址）或 `IP:端口`；无法识别的条目忽略。
    static func parseHijack(_ entries: [String]) -> [(address: IPAddress?, port: UInt16)] {
        entries.compactMap { entry in
            guard let colon = entry.lastIndex(of: ":"), let port = UInt16(entry[entry.index(after: colon)...]) else {
                return nil
            }
            var host = String(entry[..<colon])
            if host.hasPrefix("["), host.hasSuffix("]") {
                host = String(host.dropFirst().dropLast())
            }
            if host == "*" { return (nil, port) }
            guard let address = IPAddress(host) else { return nil }
            return (address, port)
        }
    }

    /// 是否为应交给 DNS 服务的目标（TUN 的 DNS 地址，或命中 `hijack-dns`）。
    public func isDNSTarget(_ address: IPAddress, port: UInt16) -> Bool {
        if address == RuntimeConfiguration.tunnelDNSAddress, port == 53 { return true }
        return hijackDNS.contains { entry in
            entry.port == port && (entry.address == nil || entry.address == address.unmappedIPv4)
        }
    }

    /// 隧道 DNS 服务的地址（docs/06 §3）。
    public static let tunnelDNSAddress = IPAddress.v4(IPv4Address(198, 18, 0, 2))

    /// 前 3 个非隐藏的 `select` 组（状态快照的 `primaryGroups`）。
    public var primarySelectGroups: [PolicyGroup] {
        groupOrder.compactMap { name -> PolicyGroup? in
            guard case .group(let group) = policies[name], group.type == .select, !group.hidden else { return nil }
            return group
        }.prefix(3).map { $0 }
    }
}
