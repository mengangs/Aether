import AetherFoundation

/// `[General]` 的类型化（docs/04 §4）。输入是叠加后的键值序列，后出现者生效。
enum GeneralParser {
    static let knownKeys: Set<String> = [
        "loglevel", "dns-server", "encrypted-dns-server", "encrypted-dns-skip-cert-verify", "dns-mode",
        "fake-ip-range", "always-real-ip", "hijack-dns", "ipv6", "skip-proxy", "exclude-simple-hostnames",
        "system-proxy", "tun-included-routes", "tun-excluded-routes", "tun-mtu", "sniffing", "block-quic",
        "udp-policy-not-supported-behaviour", "internet-test-url", "proxy-test-url", "test-timeout", "geoip-db-url",
        "geoip-maxmind-url", "ipasn-db-url", "resource-update-interval", "resource-fetch-policy",
        "show-error-page-for-reject", "http-api", "http-api-tls", "allow-wifi-access", "wifi-access-http-port",
        "wifi-access-socks5-port",
    ]

    static func parse(
        _ entries: [KeyedEntry], sink: inout DiagnosticSink, resources: inout [ExternalResourceRef]
    ) -> GeneralSettings {
        var settings = GeneralSettings()
        for entry in entries {
            apply(entry, to: &settings, sink: &sink, resources: &resources)
        }
        return settings
    }

    private static func apply(
        _ entry: KeyedEntry, to settings: inout GeneralSettings, sink: inout DiagnosticSink,
        resources: inout [ExternalResourceRef]
    ) {
        let value = entry.value
        let line = entry.source.line
        func invalid(_ expected: String) {
            sink.report(
                .cfgInvalidValue, line: line, arguments: [entry.key, value],
                "Invalid value for \(entry.key): expected \(expected)")
        }
        func bool(_ assign: (Bool) -> Void) {
            if let parsed = ValueParser.bool(value) { assign(parsed) } else { invalid("a boolean") }
        }
        func seconds(_ assign: (Double) -> Void) {
            if let parsed = ValueParser.seconds(value) { assign(parsed) } else { invalid("a number of seconds") }
        }
        func url(_ assign: (String) -> Void) {
            let lower = value.lowercased()
            guard lower.hasPrefix("http://") || lower.hasPrefix("https://"),
                ValueParser.checkResource(value) != .invalid
            else {
                invalid("an http(s) URL")
                return
            }
            assign(value)
        }
        func cidrs(_ assign: ([CIDR]) -> Void) {
            var result: [CIDR] = []
            for item in ValueParser.list(value) {
                guard let cidr = CIDR(item) else {
                    sink.report(.cfgInvalidCIDR, line: line, arguments: [item], "Invalid CIDR \(item) in \(entry.key)")
                    continue
                }
                result.append(cidr)
            }
            assign(result)
        }
        func resource(_ kind: ExternalResourceRef.Kind, _ assign: (String) -> Void) {
            switch ValueParser.checkResource(value) {
            case .invalid:
                sink.report(.cfgInvalidResourceURL, line: line, arguments: [value], "Invalid resource URL \(value)")
                return
            case .insecure:
                sink.report(.cfgInsecureResource, line: line, arguments: [value], "Resource \(value) uses plain HTTP")
            case .ok:
                break
            }
            assign(value)
            resources.append(ExternalResourceRef(url: value, kind: kind, updateInterval: nil, source: entry.source))
        }

        switch entry.key {
        case "loglevel":
            switch value.lowercased() {
            case "debug", "verbose": settings.logLevel = "debug"
            case "info": settings.logLevel = "info"
            case "notice", "notify": settings.logLevel = "notice"
            case "warning": settings.logLevel = "warning"
            case "error": settings.logLevel = "error"
            default: invalid("debug, info, notice, warning or error")
            }
        case "dns-server":
            let items = ValueParser.list(value)
            let bad = items.filter { $0.lowercased() != "system" && !ValueParser.hostPort($0, allowWildcard: false) }
            if bad.isEmpty, !items.isEmpty {
                settings.dnsServers = items.map { $0.lowercased() == "system" ? "system" : $0 }
            } else {
                invalid("system or IP[:port]")
            }
        case "encrypted-dns-server":
            var servers: [String] = []
            for item in ValueParser.list(value) {
                let lower = item.lowercased()
                if lower.hasPrefix("https://") || lower.hasPrefix("tls://") {
                    servers.append(item)
                } else if lower.hasPrefix("quic://") {
                    sink.report(
                        .cfgCompatibilityNote, line: line, arguments: [item],
                        "DNS over QUIC (\(item)) is planned for a later version and is ignored")
                } else {
                    sink.report(
                        .cfgInvalidValue, line: line, arguments: [entry.key, item],
                        "Unsupported encrypted DNS server \(item)")
                }
            }
            settings.encryptedDNSServers = servers
        case "encrypted-dns-skip-cert-verify": bool { settings.encryptedDNSSkipCertVerify = $0 }
        case "dns-mode":
            if let mode = GeneralSettings.DNSMode(rawValue: value.lowercased()) {
                settings.dnsMode = mode
            } else {
                invalid("fake-ip or real-ip")
            }
        case "fake-ip-range":
            if let cidr = CIDR(value), cidr.network.isIPv4, cidr.prefixLength <= 24 {
                settings.fakeIPRange = cidr
            } else {
                invalid("an IPv4 CIDR no smaller than /24")
            }
        case "always-real-ip":
            let items = ValueParser.list(value)
            if items.allSatisfy(ValueParser.isValidWildcard) {
                settings.alwaysRealIP = items
            } else {
                invalid("domain patterns")
            }
        case "hijack-dns":
            let items = ValueParser.list(value)
            if items.allSatisfy({ ValueParser.hostPort($0, allowWildcard: true) }) {
                settings.hijackDNS = items
            } else {
                invalid("IP:port or *:port")
            }
        case "ipv6":
            bool { settings.ipv6 = $0 }
            if settings.ipv6 {
                sink.report(
                    .cfgCompatibilityNote, line: line, arguments: [entry.key],
                    "IPv6 proxying arrives in a later version (M7)")
            }
        case "skip-proxy":
            let items = ValueParser.list(value)
            if items.allSatisfy({ CIDR($0) != nil || ValueParser.isValidWildcard($0) }) {
                settings.skipProxy = items
            } else {
                invalid("CIDRs or domain patterns")
            }
        case "exclude-simple-hostnames": bool { settings.excludeSimpleHostnames = $0 }
        case "system-proxy": bool { settings.systemProxy = $0 }
        case "tun-included-routes": cidrs { settings.tunIncludedRoutes = $0 }
        case "tun-excluded-routes": cidrs { settings.tunExcludedRoutes = $0 }
        case "tun-mtu":
            if let mtu = ValueParser.integer(value, in: 1280...9000) {
                settings.tunMTU = mtu
            } else {
                invalid("1280–9000")
            }
        case "sniffing": bool { settings.sniffing = $0 }
        case "block-quic":
            if let mode = GeneralSettings.BlockQUIC(rawValue: value.lowercased()) {
                settings.blockQUIC = mode
            } else {
                invalid("auto, always or never")
            }
        case "udp-policy-not-supported-behaviour":
            let upper = value.uppercased()
            if upper == "DIRECT" || upper == "REJECT" {
                settings.udpPolicyNotSupportedBehaviour = upper
            } else {
                invalid("DIRECT or REJECT")
            }
        case "internet-test-url": url { settings.internetTestURL = $0 }
        case "proxy-test-url": url { settings.proxyTestURL = $0 }
        case "test-timeout": seconds { settings.testTimeout = $0 }
        case "geoip-db-url", "geoip-maxmind-url": resource(.geoIPDatabase) { settings.geoIPDatabaseURL = $0 }
        case "ipasn-db-url": resource(.ipASNDatabase) { settings.ipASNDatabaseURL = $0 }
        case "resource-update-interval": seconds { settings.resourceUpdateInterval = max($0, 60) }
        case "resource-fetch-policy":
            if value.isEmpty { invalid("a policy name") } else { settings.resourceFetchPolicy = value }
        case "show-error-page-for-reject": bool { settings.showErrorPageForReject = $0 }
        case "http-api":
            let parts = value.split(separator: "@", maxSplits: 1)
            if parts.count == 2, !parts[0].isEmpty, ValueParser.hostPort(String(parts[1]), allowWildcard: false) {
                settings.httpAPI = value
                sink.report(
                    .cfgCompatibilityNote, line: line, arguments: [entry.key],
                    "The HTTP control API arrives in a later version (M7)")
            } else {
                invalid("key@address:port")
            }
        case "http-api-tls": bool { settings.httpAPITLS = $0 }
        case "allow-wifi-access":
            bool { settings.allowWiFiAccess = $0 }
            if settings.allowWiFiAccess {
                sink.report(
                    .cfgCompatibilityNote, line: line, arguments: [entry.key],
                    "Wi-Fi access arrives in a later version (M7)")
            }
        case "wifi-access-http-port":
            if let port = ValueParser.integer(value, in: 1...65535) {
                settings.wifiAccessHTTPPort = port
            } else {
                invalid("a port")
            }
        case "wifi-access-socks5-port":
            if let port = ValueParser.integer(value, in: 1...65535) {
                settings.wifiAccessSOCKS5Port = port
            } else {
                invalid("a port")
            }
        default:
            sink.report(
                .cfgUnknownKey, line: line, arguments: [entry.key], "Unknown [General] key \(entry.key); kept as is")
        }
    }
}

/// `[MITM]` 的类型化（docs/04 §11）。
enum MITMParser {
    static func parse(_ entries: [KeyedEntry], sink: inout DiagnosticSink) -> MITMSpec {
        var spec = MITMSpec()
        for entry in entries {
            let line = entry.source.line
            switch entry.key {
            case "hostname":
                spec.hostnames = ValueParser.list(entry.value).compactMap { item in
                    guard let pattern = hostnamePattern(item) else {
                        sink.report(
                            .cfgInvalidMITMHostname, line: line, arguments: [item], "Invalid MITM hostname \(item)")
                        return nil
                    }
                    if pattern.host == "*", pattern.port == nil, !pattern.isExclusion {
                        sink.report(
                            .cfgMITMWildcardAll, line: line, arguments: [item], "MITM hostname '*' decrypts every host")
                    }
                    return pattern
                }
            case "skip-server-cert-verify", "auto-quic-block", "h2":
                guard let flag = ValueParser.bool(entry.value) else {
                    sink.report(
                        .cfgInvalidValue, line: line, arguments: [entry.key, entry.value],
                        "Invalid boolean for \(entry.key)")
                    continue
                }
                switch entry.key {
                case "skip-server-cert-verify": spec.skipServerCertVerify = flag
                case "auto-quic-block": spec.autoQUICBlock = flag
                default:
                    spec.h2 = flag
                    if flag {
                        sink.report(
                            .cfgCompatibilityNote, line: line, arguments: [entry.key],
                            "HTTP/2 MITM arrives in a later version (M7)")
                    }
                }
            case "ca-p12": spec.caP12 = entry.value
            case "ca-passphrase": spec.caPassphrase = entry.value
            default:
                sink.report(
                    .cfgUnknownKey, line: line, arguments: [entry.key], "Unknown [MITM] key \(entry.key); kept as is")
            }
        }
        return spec
    }

    /// `example.com`、`*.example.com`、`example.com:8443`、`*:8443`、`-example.com`、`*`。
    static func hostnamePattern(_ text: String) -> MITMSpec.HostnamePattern? {
        var body = Substring(text)
        var exclusion = false
        if body.hasPrefix("-") {
            exclusion = true
            body = body.dropFirst()
        }
        var port: UInt16?
        if let colon = body.lastIndex(of: ":") {
            guard let value = ValueParser.integer(String(body[body.index(after: colon)...]), in: 1...65535) else {
                return nil
            }
            port = UInt16(value)
            body = body[..<colon]
        }
        let host = body.lowercased()
        guard !host.isEmpty, ValueParser.isValidWildcard(host), !host.contains("/") else { return nil }
        return MITMSpec.HostnamePattern(host: host, port: port, isExclusion: exclusion)
    }
}
