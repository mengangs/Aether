import AetherFoundation

/// `[Proxy]` 条目的类型化（docs/04 §5）。
enum ProxyParser {
    static let commonParameters: Set<String> = [
        "udp-relay", "test-url", "test-timeout", "ip-version", "block-quic", "underlying-proxy", "tfo",
    ]
    static let tlsParameters: Set<String> = ["sni", "skip-cert-verify", "server-cert-fingerprint-sha256", "alpn"]
    static let webSocketParameters: Set<String> = ["ws", "ws-path", "ws-headers"]
    static let unavailableTypes: Set<String> = [
        "hysteria2", "tuic", "tuic-v5", "wireguard", "snell", "ssh", "external", "tailscale", "ssr", "shadowsocksr",
        "hysteria", "juicity", "anytls", "trust-tunnel", "ss-r",
    ]

    /// - Parameters:
    ///   - name: `=` 左侧。
    ///   - value: `=` 右侧。
    static func parse(name: String, value: String, source: SourceReference, sink: inout DiagnosticSink) -> ProxySpec? {
        let line = source.line
        guard case .success(let fields) = FieldTokenizer.split(value) else {
            sink.report(
                .cfgSyntax, line: line, arguments: [name], "Proxy \(name) has an unterminated quote or parenthesis")
            return nil
        }
        let type = fields[0].value.lowercased()
        guard !type.isEmpty else {
            sink.report(.cfgSyntax, line: line, arguments: [name], "Proxy \(name) has no type")
            return nil
        }
        if let builtin = BuiltinPolicy(aliasType: type) {
            return ProxySpec(name: name, type: type, proxyProtocol: .alias(builtin), source: source)
        }

        var positional: [String] = []
        var parameters: [(key: String, value: String)] = []
        for field in fields.dropFirst() {
            if let pair = FieldTokenizer.keyValue(field) {
                parameters.append(pair)
            } else if parameters.isEmpty {
                positional.append(field.value)
            } else {
                sink.report(
                    .cfgSyntax, line: line, arguments: [name, field.raw],
                    "Positional field \(field.raw) after key=value parameters in proxy \(name)")
            }
        }
        var params: [String: String] = [:]
        for (key, value) in parameters {
            params[key] = value
        }

        if unavailableTypes.contains(type) {
            sink.report(
                .cfgUnsupportedProxyType, line: line, arguments: [name, type],
                "Proxy type \(type) is not supported; \(name) is unavailable")
            var spec = ProxySpec(name: name, type: type, proxyProtocol: .unavailable(type: type), source: source)
            spec.server = positional.first
            return spec
        }

        let supported: Set<String> = ["http", "https", "socks5", "socks5-tls", "ss", "trojan", "vmess", "vless"]
        guard supported.contains(type) else {
            sink.report(
                .cfgUnsupportedProxyType, line: line, arguments: [name, type],
                "Unknown proxy type \(type); \(name) is unavailable")
            return ProxySpec(name: name, type: type, proxyProtocol: .unavailable(type: type), source: source)
        }

        guard positional.count >= 2 else {
            sink.report(
                .cfgMissingParameter, line: line, arguments: [name, "server, port"],
                "Proxy \(name) needs a server and a port")
            return nil
        }
        let server = positional[0]
        guard !server.isEmpty, Hostname(server) != nil || IPAddress(server) != nil else {
            sink.report(
                .cfgInvalidValue, line: line, arguments: [name, server], "Invalid server \(server) in proxy \(name)")
            return nil
        }
        guard let port = ValueParser.integer(positional[1], in: 1...65535) else {
            sink.report(
                .cfgInvalidValue, line: line, arguments: [name, positional[1]],
                "Invalid port \(positional[1]) in proxy \(name)")
            return nil
        }

        var allowed = commonParameters
        let usesTLSParameters: Bool
        let usesWebSocket: Bool
        switch type {
        case "http", "https":
            allowed.formUnion(["username", "password", "always-use-connect"])
            usesTLSParameters = type == "https"
            usesWebSocket = false
        case "socks5", "socks5-tls":
            allowed.formUnion(["username", "password"])
            usesTLSParameters = type == "socks5-tls"
            usesWebSocket = false
        case "ss":
            allowed.formUnion(["encrypt-method", "password", "obfs", "obfs-host", "obfs-uri"])
            usesTLSParameters = false
            usesWebSocket = false
        case "trojan":
            allowed.formUnion(["password"])
            usesTLSParameters = true
            usesWebSocket = true
        case "vmess":
            allowed.formUnion(["username", "encrypt-method", "vmess-aead", "tls", "alterid"])
            usesTLSParameters = true
            usesWebSocket = true
        default:  // vless
            allowed.formUnion(["username", "tls", "flow"])
            usesTLSParameters = true
            usesWebSocket = true
        }
        if usesTLSParameters { allowed.formUnion(tlsParameters) }
        if usesWebSocket { allowed.formUnion(webSocketParameters) }
        for (key, _) in parameters where !allowed.contains(key) {
            sink.report(
                .cfgUnknownKey, line: line, arguments: [name, key],
                "Unknown parameter \(key) for \(type) proxy \(name); kept as is")
        }

        func flag(_ key: String, default value: Bool = false) -> Bool {
            guard let raw = params[key] else { return value }
            guard let parsed = ValueParser.bool(raw) else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: [key, raw],
                    "Invalid boolean \(raw) for \(key) in proxy \(name)")
                return value
            }
            return parsed
        }
        func credential(_ index: Int, _ key: String) -> String? {
            params[key] ?? (positional.count > index ? positional[index] : nil)
        }

        let proxyProtocol: ProxyProtocol
        switch type {
        case "http", "https":
            proxyProtocol = .http(
                username: credential(2, "username"), password: credential(3, "password"),
                alwaysUseConnect: flag("always-use-connect"))
        case "socks5", "socks5-tls":
            proxyProtocol = .socks5(username: credential(2, "username"), password: credential(3, "password"))
        case "ss":
            guard let methodName = params["encrypt-method"]?.lowercased(), let password = params["password"] else {
                sink.report(
                    .cfgMissingParameter, line: line, arguments: [name, "encrypt-method, password"],
                    "Shadowsocks proxy \(name) needs encrypt-method and password")
                return nil
            }
            var obfs: SimpleObfs?
            if let mode = params["obfs"] {
                guard let parsed = SimpleObfs.Mode(rawValue: mode.lowercased()) else {
                    sink.report(
                        .cfgInvalidValue, line: line, arguments: ["obfs", mode],
                        "obfs must be http or tls in proxy \(name)")
                    return nil
                }
                obfs = SimpleObfs(mode: parsed, host: params["obfs-host"], uri: params["obfs-uri"])
            }
            if let method = ShadowsocksMethod(rawValue: methodName) {
                proxyProtocol = .shadowsocks(method: method, password: password, obfs: obfs)
            } else if ShadowsocksMethod.insecureStreamCiphers.contains(methodName) {
                sink.report(
                    .cfgUnsupportedCipher, line: line, arguments: [name, methodName],
                    "Stream cipher \(methodName) is insecure and unsupported; \(name) is unavailable")
                proxyProtocol = .unavailable(type: type)
            } else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["encrypt-method", methodName],
                    "Unknown Shadowsocks method \(methodName)")
                return nil
            }
        case "trojan":
            guard let password = params["password"] else {
                sink.report(
                    .cfgMissingParameter, line: line, arguments: [name, "password"],
                    "Trojan proxy \(name) needs a password")
                return nil
            }
            proxyProtocol = .trojan(password: password)
        case "vmess":
            guard let uuid = params["username"] else {
                sink.report(
                    .cfgMissingParameter, line: line, arguments: [name, "username"],
                    "VMess proxy \(name) needs a UUID username")
                return nil
            }
            guard isUUID(uuid) else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["username", uuid], "VMess username must be a UUID")
                return nil
            }
            let cipherName = params["encrypt-method"]?.lowercased() ?? "auto"
            guard let cipher = VMessCipher(rawValue: cipherName) else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["encrypt-method", cipherName],
                    "Unknown VMess cipher \(cipherName)")
                return nil
            }
            let alterID = params["alterid"].flatMap { Int($0) } ?? 0
            if !flag("vmess-aead", default: true) || alterID > 0 {
                sink.report(
                    .cfgUnsupportedCipher, line: line, arguments: [name, "legacy VMess"],
                    "Legacy (non-AEAD) VMess is unsupported; \(name) is unavailable")
                proxyProtocol = .unavailable(type: type)
            } else {
                proxyProtocol = .vmess(uuid: uuid.lowercased(), cipher: cipher)
            }
        default:  // vless
            guard let uuid = params["username"] else {
                sink.report(
                    .cfgMissingParameter, line: line, arguments: [name, "username"],
                    "VLESS proxy \(name) needs a UUID username")
                return nil
            }
            guard isUUID(uuid) else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["username", uuid], "VLESS username must be a UUID")
                return nil
            }
            if let flow = params["flow"], !flow.isEmpty {
                sink.report(
                    .cfgUnsupportedCipher, line: line, arguments: [name, "flow=\(flow)"],
                    "VLESS flow \(flow) (XTLS) is unsupported; \(name) is unavailable")
                proxyProtocol = .unavailable(type: type)
            } else {
                proxyProtocol = .vless(uuid: uuid.lowercased())
            }
        }

        var spec = ProxySpec(name: name, type: type, proxyProtocol: proxyProtocol, source: source)
        spec.server = server
        spec.port = UInt16(port)
        spec.udpRelay = flag("udp-relay")
        if let url = params["test-url"] { spec.testURL = url }
        if let raw = params["test-timeout"] {
            if let value = ValueParser.seconds(raw) {
                spec.testTimeout = value
            } else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["test-timeout", raw],
                    "Invalid test-timeout in proxy \(name)")
            }
        }
        if let raw = params["ip-version"] {
            if let value = IPVersionPreference(rawValue: raw.lowercased()) {
                spec.ipVersion = value
            } else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["ip-version", raw], "Invalid ip-version in proxy \(name)")
            }
        }
        if let raw = params["block-quic"] {
            if ["auto", "on", "off"].contains(raw.lowercased()) {
                spec.blockQUIC = raw.lowercased()
            } else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["block-quic", raw], "block-quic must be auto, on or off")
            }
        }
        if let underlying = params["underlying-proxy"] {
            spec.underlyingProxy = underlying
            sink.report(
                .cfgCompatibilityNote, line: line, arguments: ["underlying-proxy"],
                "Proxy chains arrive in a later version (M7)")
        }
        if params["tfo"] != nil {
            sink.report(
                .cfgIgnoredOnIOS, line: line, arguments: ["tfo"], "TCP Fast Open is not available on iOS; ignored")
        }

        let tlsEnabled =
            type == "https" || type == "socks5-tls" || type == "trojan"
            || ((type == "vmess" || type == "vless") && flag("tls"))
        if tlsEnabled {
            spec.tls = tlsOptions(params, proxy: name, line: line, sink: &sink)
        } else if usesTLSParameters, params.keys.contains(where: tlsParameters.contains) {
            sink.report(
                .cfgUnknownKey, line: line, arguments: [name, "tls"],
                "TLS parameters in \(name) have no effect without tls=true")
        }
        if usesWebSocket, flag("ws") {
            var ws = WebSocketOptions()
            if let path = params["ws-path"] { ws.path = path.isEmpty ? "/" : path }
            if let raw = params["ws-headers"] {
                ws.headers = headers(raw)
            }
            spec.webSocket = ws
        }
        return spec
    }

    static func tlsOptions(_ params: [String: String], proxy: String, line: Int, sink: inout DiagnosticSink)
        -> TLSOptions
    {
        var options = TLSOptions()
        if let sni = params["sni"] {
            options.sni = sni.lowercased() == "off" ? .disabled : .custom(sni)
        }
        if let raw = params["skip-cert-verify"] {
            if let value = ValueParser.bool(raw) {
                options.skipCertVerify = value
            } else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["skip-cert-verify", raw],
                    "Invalid boolean in proxy \(proxy)")
            }
        }
        if let raw = params["server-cert-fingerprint-sha256"] {
            if let bytes = Bytes.fromHex(raw), bytes.count == 32 {
                options.certificateFingerprintSHA256 = bytes
            } else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["server-cert-fingerprint-sha256", raw],
                    "Fingerprint must be 64 hex digits in proxy \(proxy)")
            }
        }
        if let raw = params["alpn"] {
            options.alpn = raw.split(separator: ",").map { String($0).trimmingWhitespace() }.filter { !$0.isEmpty }
        }
        return options
    }

    /// `名:值` 以 `|` 分隔。
    static func headers(_ raw: String) -> [HTTPHeaderField] {
        raw.split(separator: "|").compactMap { item in
            guard let colon = item.firstIndex(of: ":") else { return nil }
            let name = String(item[..<colon]).trimmingWhitespace()
            guard !name.isEmpty else { return nil }
            return HTTPHeaderField(name: name, value: String(item[colon...].dropFirst()).trimmingWhitespace())
        }
    }

    static func isUUID(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isHexDigit) }
    }
}

/// `[Proxy Group]` 条目的类型化（docs/04 §6）。
enum GroupParser {
    static let allParameters: Set<String> = [
        "policy-path", "update-interval", "policy-regex-filter", "include-all-proxies", "include-other-group", "hidden",
        "url", "interval", "timeout", "tolerance", "evaluate-before-use", "persistent",
    ]

    static func parse(name: String, value: String, source: SourceReference, sink: inout DiagnosticSink)
        -> PolicyGroupSpec?
    {
        let line = source.line
        guard case .success(let fields) = FieldTokenizer.split(value) else {
            sink.report(
                .cfgSyntax, line: line, arguments: [name], "Group \(name) has an unterminated quote or parenthesis")
            return nil
        }
        let typeName = fields[0].value.lowercased()
        guard let type = PolicyGroupSpec.GroupType(rawValue: typeName) else {
            sink.report(
                .cfgInvalidValue, line: line, arguments: [name, typeName], "Unknown group type \(typeName) in \(name)")
            return nil
        }
        var members: [String] = []
        var params: [String: String] = [:]
        for field in fields.dropFirst() {
            if let (key, value) = FieldTokenizer.keyValue(field) {
                // 策略名不可能含 `=`（它是 [Proxy] 条目的左侧），所以含 `=` 的字段一定是参数。
                if allParameters.contains(key) {
                    params[key] = value
                } else {
                    sink.report(
                        .cfgUnknownKey, line: line, arguments: [name, key],
                        "Unknown parameter \(key) in group \(name); kept as is")
                }
            } else if !field.value.isEmpty {
                members.append(field.value)
            }
        }
        var group = PolicyGroupSpec(name: name, type: type, members: members, source: source)
        if type == .subnet {
            sink.report(
                .cfgCompatibilityNote, line: line, arguments: [name], "subnet groups arrive in a later version (M7)")
        }

        let automaticOnly: Set<String> = ["url", "interval", "timeout"]
        for key in params.keys {
            let applicable: Bool
            switch key {
            case _ where automaticOnly.contains(key): applicable = type.isAutomatic
            case "tolerance": applicable = type == .urlTest
            case "evaluate-before-use": applicable = type == .urlTest || type == .fallback
            case "persistent": applicable = type == .loadBalance
            default: applicable = true
            }
            if !applicable {
                sink.report(
                    .cfgUnknownKey, line: line, arguments: [name, key],
                    "Parameter \(key) does not apply to \(typeName) group \(name)")
            }
        }
        func seconds(_ key: String) -> Double? {
            guard let raw = params[key] else { return nil }
            guard let value = ValueParser.seconds(raw) else {
                sink.report(.cfgInvalidValue, line: line, arguments: [key, raw], "Invalid \(key) in group \(name)")
                return nil
            }
            return value
        }
        func flag(_ key: String) -> Bool {
            guard let raw = params[key] else { return false }
            guard let value = ValueParser.bool(raw) else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: [key, raw], "Invalid boolean for \(key) in group \(name)")
                return false
            }
            return value
        }
        if let path = params["policy-path"] {
            switch ValueParser.checkResource(path) {
            case .invalid:
                sink.report(
                    .cfgInvalidResourceURL, line: line, arguments: [path], "Invalid policy-path in group \(name)")
            case .insecure:
                sink.report(
                    .cfgInsecureResource, line: line, arguments: [path], "policy-path of \(name) uses plain HTTP")
                group.policyPath = path
            case .ok:
                group.policyPath = path
            }
        }
        group.updateInterval = seconds("update-interval")
        if let regex = params["policy-regex-filter"] {
            if ValueParser.isValidRegex(regex) {
                group.policyRegexFilter = regex
            } else {
                sink.report(
                    .cfgInvalidRegex, line: line, arguments: [regex], "Invalid policy-regex-filter in group \(name)")
            }
        }
        group.includeAllProxies = flag("include-all-proxies")
        if let raw = params["include-other-group"] {
            group.includeOtherGroups = raw.split(separator: ",").map { String($0).trimmingWhitespace() }.filter {
                !$0.isEmpty
            }
        }
        group.hidden = flag("hidden")
        group.url = params["url"]
        if let interval = seconds("interval") { group.interval = max(interval, 1) }
        group.timeout = seconds("timeout")
        if let raw = params["tolerance"] {
            if let value = ValueParser.integer(raw, in: 0...100_000) {
                group.tolerance = value
            } else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["tolerance", raw], "Invalid tolerance in group \(name)")
            }
        }
        group.evaluateBeforeUse = flag("evaluate-before-use")
        group.persistent = flag("persistent")
        return group
    }
}
