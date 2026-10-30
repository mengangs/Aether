import AetherDNS
import AetherEngine
import AetherFoundation
import AetherProfile
import Dispatch
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// `aether-cli run <配置> [--socks 地址:端口] [--http 地址:端口] [--module 模块]...`（docs/13 §4）：
/// 在本机以 SOCKS5（无认证）与 HTTP 代理入站运行同一套引擎，Ctrl-C 停止。系统 DNS 取自 `/etc/resolv.conf`；
/// 本地规则集相对配置文件所在目录读取，远程资源不下载（视为未加载）。
func runEngine(_ arguments: [String]) async throws -> Int32 {
    var rest = arguments
    func take(_ flag: String) throws -> String? {
        guard let index = rest.firstIndex(of: flag) else { return nil }
        guard index + 1 < rest.count else { throw CLIError(message: "\(flag) 需要一个值") }
        let value = rest[index + 1]
        rest.removeSubrange(index...(index + 1))
        return value
    }
    func endpoint(_ text: String) throws -> (host: String, port: Int) {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]),
            (0...65535).contains(port)
        else { throw CLIError(message: "地址应为 主机:端口：\(text)") }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return (host, port)
    }
    let socks = try endpoint(try take("--socks") ?? "127.0.0.1:1080")
    let http = try take("--http").map(endpoint)
    var modules: [ProfileInspector.Source] = []
    while let module = try take("--module") {
        modules.append(try readSource(module))
    }
    guard rest.count == 1 else { throw CLIError(message: "run 需要一个配置文件") }
    let profilePath = rest[0]
    let profile = try readSource(profilePath)
    let resolved = ProfileInspector.resolve(profile, modules: modules)
    guard resolved.isCommittable else {
        print(ProfileInspector.check(profile, modules: modules).output, terminator: "")
        return 1
    }
    let directory = URL(fileURLWithPath: profilePath).deletingLastPathComponent()
    var contents: [String: String] = [:]
    for resource in resolved.externalResources where !resource.isRemote {
        if let data = FileManager.default.contents(atPath: directory.appendingPathComponent(resource.url).path) {
            contents[resource.url] = String(decoding: data, as: UTF8.self)
        }
    }
    let (resources, notes) = ProfileInspector.ruleResources(resolved, contents: contents)
    for note in notes {
        print(note)
    }
    let configuration = RuntimeConfiguration.compile(
        resolved, profileID: profile.name, profileName: profile.name, resources: resources)

    var options = Engine.Options()
    options.socksHost = socks.host
    options.socksPort = socks.port
    options.socksCredentials = nil
    options.httpProxy = http
    options.systemDNSServers = {
        let text = (try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8)) ?? ""
        return ResolvConf.nameservers(from: text)
    }
    AetherLogging.bootstrap(
        .init(subsystem: "aether-cli", fileDirectory: nil, fileBaseName: "cli", level: .info, writesToSystemLog: false))
    var forceHTTP = configuration
    if http != nil, !configuration.general.systemProxy {
        print("note: system-proxy = false; the HTTP inbound starts anyway because --http was given")
        forceHTTP = RuntimeConfiguration.compile(
            withSystemProxy(resolved), profileID: profile.name, profileName: profile.name, resources: resources)
    }
    let engine = try await Engine.start(configuration: forceHTTP, options: options)
    print("SOCKS5 listening on \(socks.host):\(engine.socks.port)")
    if let inbound = engine.httpProxyInbound {
        print("HTTP proxy listening on \(http?.host ?? "127.0.0.1"):\(inbound.port)")
    }
    print("Press Ctrl-C to stop.")
    await waitForTermination()
    print("Stopping…")
    await engine.stop()
    return 0
}

private func withSystemProxy(_ resolved: ResolvedProfile) -> ResolvedProfile {
    var copy = resolved
    copy.general.systemProxy = true
    return copy
}

/// 等待 SIGINT 或 SIGTERM。
private func waitForTermination() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let queue = DispatchQueue(label: "aether-cli.signals")
        let once = OneShot<Void> { continuation.resume() }
        var sources: [any DispatchSourceSignal] = []
        for signalNumber in [SIGINT, SIGTERM] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler { once(()) }
            source.resume()
            sources.append(source)
        }
        // 信号源须在等待期间保持存活。
        SignalSources.keep(sources)
    }
}

/// 保持信号源的引用直到进程结束。
private enum SignalSources {
    nonisolated(unsafe) static var retained: [any DispatchSourceSignal] = []

    static func keep(_ sources: [any DispatchSourceSignal]) {
        retained = sources
    }
}
