import AetherFoundation

/// `[Host]`、重写类节、`[Map Local]`、`[Script]` 的类型化（docs/04 §8–§10）。
enum SectionParsers {
    // MARK: [Host]

    static func host(pattern: String, value: String, source: SourceReference, sink: inout DiagnosticSink) -> HostSpec? {
        let line = source.line
        // 与规则中的主机名一致：Unicode 标签转为 Punycode（通配标签 `*`、`?` 是 ASCII，不受影响）。
        let normalizedPattern = Hostname(pattern)?.value ?? pattern.lowercased()
        guard ValueParser.isValidWildcard(normalizedPattern) else {
            sink.report(.cfgInvalidHost, line: line, arguments: [pattern], "Invalid [Host] pattern \(pattern)")
            return nil
        }
        let lower = value.lowercased()
        if lower.hasPrefix("server:") {
            let target = String(value.dropFirst("server:".count)).trimmingWhitespace()
            let lowerTarget = target.lowercased()
            if lowerTarget.hasPrefix("script:") {
                sink.report(
                    .cfgCompatibilityNote, line: line, arguments: [pattern],
                    "DNS scripts arrive in a later version (M7)")
                return HostSpec(
                    pattern: normalizedPattern, value: .script(String(target.dropFirst("script:".count))),
                    source: source)
            }
            let valid =
                lowerTarget == "system" || lowerTarget.hasPrefix("https://") || lowerTarget.hasPrefix("tls://")
                || ValueParser.hostPort(target, allowWildcard: false)
            guard valid else {
                sink.report(
                    .cfgInvalidHost, line: line, arguments: [pattern, value], "Invalid DNS server \(target) in [Host]")
                return nil
            }
            return HostSpec(pattern: normalizedPattern, value: .server(target), source: source)
        }
        let items = ValueParser.list(value)
        let addresses = items.compactMap(IPAddress.init)
        if !items.isEmpty, addresses.count == items.count {
            return HostSpec(pattern: normalizedPattern, value: .addresses(addresses), source: source)
        }
        if items.count == 1, let alias = Hostname(items[0]) {
            return HostSpec(pattern: normalizedPattern, value: .alias(alias), source: source)
        }
        sink.report(.cfgInvalidHost, line: line, arguments: [pattern, value], "Invalid [Host] value \(value)")
        return nil
    }

    // MARK: [URL Rewrite]

    static func urlRewrite(_ text: String, source: SourceReference, sink: inout DiagnosticSink) -> URLRewriteSpec? {
        guard let fields = whitespaceFields(text, source: source, sink: &sink) else { return nil }
        guard fields.count == 3 else {
            sink.report(.cfgInvalidRewrite, line: source.line, "URL rewrite needs: regex replacement type")
            return nil
        }
        guard let action = URLRewriteSpec.Action(rawValue: fields[2].lowercased()) else {
            sink.report(
                .cfgInvalidRewrite, line: source.line, arguments: [fields[2]], "Unknown URL rewrite type \(fields[2])")
            return nil
        }
        guard regex(fields[0], source: source, sink: &sink) else { return nil }
        return URLRewriteSpec(pattern: fields[0], replacement: fields[1], action: action, source: source)
    }

    // MARK: [Header Rewrite]

    static func headerRewrite(_ text: String, source: SourceReference, sink: inout DiagnosticSink) -> HeaderRewriteSpec?
    {
        guard var fields = whitespaceFields(text, source: source, sink: &sink), !fields.isEmpty else { return nil }
        var phase = HeaderRewriteSpec.Phase.request
        if let explicit = HeaderRewriteSpec.Phase(rawValue: fields[0].lowercased()) {
            phase = explicit
            fields.removeFirst()
        }
        guard fields.count >= 3 else {
            sink.report(.cfgInvalidRewrite, line: source.line, "Header rewrite needs: [phase] regex operation name …")
            return nil
        }
        let pattern = fields[0]
        let name = fields[2]
        let operation: HeaderRewriteSpec.Operation
        switch (fields[1].lowercased(), fields.count) {
        case ("header-add", 4): operation = .add(name: name, value: fields[3])
        case ("header-del", 3): operation = .delete(name: name)
        case ("header-replace", 4): operation = .replace(name: name, value: fields[3])
        case ("header-replace-regex", 5):
            guard regex(fields[3], source: source, sink: &sink) else { return nil }
            operation = .replaceRegex(name: name, pattern: fields[3], replacement: fields[4])
        default:
            sink.report(
                .cfgInvalidRewrite, line: source.line, arguments: [fields[1]],
                "Invalid header rewrite operation \(fields[1])")
            return nil
        }
        guard regex(pattern, source: source, sink: &sink) else { return nil }
        return HeaderRewriteSpec(phase: phase, pattern: pattern, operation: operation, source: source)
    }

    // MARK: [Body Rewrite]

    static func bodyRewrite(_ text: String, source: SourceReference, sink: inout DiagnosticSink) -> BodyRewriteSpec? {
        guard let fields = whitespaceFields(text, source: source, sink: &sink), !fields.isEmpty else { return nil }
        guard let phase = HeaderRewriteSpec.Phase(rawValue: fields[0].lowercased()) else {
            sink.report(
                .cfgInvalidRewrite, line: source.line, arguments: [fields[0]],
                "Body rewrite must start with http-request or http-response")
            return nil
        }
        guard fields.count >= 4, (fields.count - 2) % 2 == 0 else {
            sink.report(
                .cfgInvalidRewrite, line: source.line, "Body rewrite needs: phase url-regex (regex replacement)…")
            return nil
        }
        guard regex(fields[1], source: source, sink: &sink) else { return nil }
        var pairs: [(pattern: String, replacement: String)] = []
        var index = 2
        while index + 1 < fields.count {
            guard regex(fields[index], source: source, sink: &sink) else { return nil }
            pairs.append((fields[index], fields[index + 1]))
            index += 2
        }
        return BodyRewriteSpec(phase: phase, urlPattern: fields[1], replacements: pairs, source: source)
    }

    // MARK: [Map Local]

    static func mapLocal(
        _ text: String, source: SourceReference, sink: inout DiagnosticSink, resources: inout [ExternalResourceRef]
    ) -> MapLocalSpec? {
        guard let fields = whitespaceFieldObjects(text, source: source, sink: &sink), let first = fields.first else {
            return nil
        }
        guard regex(first.value, source: source, sink: &sink) else { return nil }
        var dataType = MapLocalSpec.DataType.text
        var data = ""
        var statusCode = 200
        var headers: [HTTPHeaderField] = []
        for field in fields.dropFirst() {
            guard let (key, value) = FieldTokenizer.keyValue(field) else {
                sink.report(
                    .cfgInvalidRewrite, line: source.line, arguments: [field.raw],
                    "Map Local parameters must be key=value")
                return nil
            }
            switch key {
            case "data-type":
                guard let parsed = MapLocalSpec.DataType(rawValue: value.lowercased()) else {
                    sink.report(.cfgInvalidRewrite, line: source.line, arguments: [value], "Unknown data-type \(value)")
                    return nil
                }
                dataType = parsed
            case "data": data = value
            case "status-code":
                guard let code = ValueParser.integer(value, in: 100...599) else {
                    sink.report(
                        .cfgInvalidRewrite, line: source.line, arguments: [value], "Invalid status-code \(value)")
                    return nil
                }
                statusCode = code
            case "header": headers = ProxyParser.headers(value)
            default:
                sink.report(
                    .cfgUnknownKey, line: source.line, arguments: [key],
                    "Unknown Map Local parameter \(key); kept as is")
            }
        }
        if dataType == .file {
            switch ValueParser.checkResource(data) {
            case .invalid:
                sink.report(
                    .cfgInvalidResourceURL, line: source.line, arguments: [data], "Invalid Map Local file \(data)")
                return nil
            case .insecure:
                sink.report(
                    .cfgInsecureResource, line: source.line, arguments: [data], "Map Local file \(data) uses plain HTTP"
                )
                fallthrough
            case .ok:
                if data.lowercased().hasPrefix("http") {
                    resources.append(
                        ExternalResourceRef(url: data, kind: .mapLocalFile, updateInterval: nil, source: source))
                }
            }
        }
        return MapLocalSpec(
            urlPattern: first.value, dataType: dataType, data: data, statusCode: statusCode, headers: headers,
            source: source)
    }

    // MARK: [Script]

    static let scriptParameters: Set<String> = [
        "type", "script-path", "script-update-interval", "timeout", "argument", "debug", "engine", "pattern",
        "requires-body", "max-size", "binary-body-mode", "cronexp", "cron-expression", "event-name", "wake-system",
    ]

    static func script(
        name: String, value: String, source: SourceReference, sink: inout DiagnosticSink,
        resources: inout [ExternalResourceRef]
    ) -> ScriptSpec? {
        let line = source.line
        guard case .success(let fields) = FieldTokenizer.split(value) else {
            sink.report(.cfgSyntax, line: line, arguments: [name], "Script \(name) has an unterminated quote")
            return nil
        }
        var params: [String: String] = [:]
        for field in fields where !field.raw.isEmpty {
            guard let (key, value) = FieldTokenizer.keyValue(field) else {
                sink.report(
                    .cfgInvalidScript, line: line, arguments: [name, field.raw], "Script parameters must be key=value")
                return nil
            }
            if !scriptParameters.contains(key) {
                sink.report(
                    .cfgUnknownKey, line: line, arguments: [name, key], "Unknown script parameter \(key); kept as is")
            }
            params[key] = value
        }
        guard let typeName = params["type"], let type = ScriptSpec.ScriptType(rawValue: typeName.lowercased()) else {
            sink.report(
                .cfgInvalidScript, line: line, arguments: [name, params["type"] ?? ""],
                "Script \(name) needs a valid type")
            return nil
        }
        guard let path = params["script-path"], !path.isEmpty else {
            sink.report(
                .cfgInvalidScript, line: line, arguments: [name, "script-path"], "Script \(name) needs script-path")
            return nil
        }
        switch ValueParser.checkResource(path) {
        case .invalid:
            sink.report(.cfgInvalidResourceURL, line: line, arguments: [path], "Invalid script-path \(path)")
            return nil
        case .insecure:
            sink.report(
                .cfgInsecureResource, line: line, arguments: [path], "Script \(name) is downloaded over plain HTTP")
        case .ok:
            break
        }
        var spec = ScriptSpec(name: name, type: type, scriptPath: path, source: source)
        func seconds(_ key: String) -> Double? {
            guard let raw = params[key] else { return nil }
            guard let value = ValueParser.seconds(raw) else {
                sink.report(.cfgInvalidValue, line: line, arguments: [key, raw], "Invalid \(key) in script \(name)")
                return nil
            }
            return value
        }
        func flag(_ key: String) -> Bool {
            guard let raw = params[key] else { return false }
            guard let value = ValueParser.bool(raw) else {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: [key, raw], "Invalid boolean for \(key) in script \(name)")
                return false
            }
            return value
        }
        if let interval = seconds("script-update-interval") { spec.updateInterval = interval }
        if let timeout = seconds("timeout") { spec.timeout = timeout }
        spec.argument = params["argument"] ?? ""
        spec.debug = flag("debug")
        if params["engine"] != nil {
            sink.report(
                .cfgCompatibilityNote, line: line, arguments: ["engine"],
                "engine is ignored: scripts always run in JavaScriptCore")
        }
        switch type {
        case .httpRequest, .httpResponse:
            guard let pattern = params["pattern"] else {
                sink.report(
                    .cfgInvalidScript, line: line, arguments: [name, "pattern"], "HTTP script \(name) needs a pattern")
                return nil
            }
            guard regex(pattern, source: source, sink: &sink) else { return nil }
            spec.pattern = pattern
            spec.requiresBody = flag("requires-body")
            spec.binaryBodyMode = flag("binary-body-mode")
            if let raw = params["max-size"] {
                if let size = ValueParser.integer(raw, in: 0...(64 << 20)) {
                    spec.maxSize = size
                } else {
                    sink.report(
                        .cfgInvalidValue, line: line, arguments: ["max-size", raw], "Invalid max-size in script \(name)"
                    )
                }
            }
        case .cron:
            guard let expression = params["cronexp"] ?? params["cron-expression"] else {
                sink.report(
                    .cfgInvalidScript, line: line, arguments: [name, "cronexp"], "cron script \(name) needs cronexp")
                return nil
            }
            do {
                spec.cronExpression = try CronExpression(expression)
            } catch {
                sink.report(
                    .cfgInvalidCron, line: line, arguments: [name, expression], "Invalid cron expression \(expression)")
                return nil
            }
        case .event:
            guard let event = params["event-name"], !event.isEmpty else {
                sink.report(
                    .cfgInvalidScript, line: line, arguments: [name, "event-name"],
                    "event script \(name) needs event-name")
                return nil
            }
            if event != "network-changed" {
                sink.report(
                    .cfgInvalidValue, line: line, arguments: ["event-name", event],
                    "Only network-changed events are supported")
            }
            spec.eventName = event
        case .dns, .rule:
            sink.report(
                .cfgCompatibilityNote, line: line, arguments: [name, type.rawValue],
                "\(type.rawValue) scripts arrive in a later version (M7)")
        case .generic:
            break
        }
        if path.lowercased().hasPrefix("http") {
            resources.append(
                ExternalResourceRef(url: path, kind: .script, updateInterval: spec.updateInterval, source: source))
        }
        return spec
    }

    // MARK: 辅助

    static func regex(_ pattern: String, source: SourceReference, sink: inout DiagnosticSink) -> Bool {
        guard ValueParser.isValidRegex(pattern) else {
            sink.report(
                .cfgInvalidRegex, line: source.line, arguments: [pattern], "Invalid regular expression \(pattern)")
            return false
        }
        return true
    }

    static func whitespaceFields(_ text: String, source: SourceReference, sink: inout DiagnosticSink) -> [String]? {
        whitespaceFieldObjects(text, source: source, sink: &sink)?.map(\.value)
    }

    static func whitespaceFieldObjects(_ text: String, source: SourceReference, sink: inout DiagnosticSink)
        -> [FieldTokenizer.Field]?
    {
        switch FieldTokenizer.splitWhitespace(text) {
        case .success(let fields): return fields
        case .failure:
            sink.report(.cfgInvalidRewrite, line: source.line, "Unterminated quote")
            return nil
        }
    }
}
