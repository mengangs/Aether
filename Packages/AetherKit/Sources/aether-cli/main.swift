import AetherEngine
import AetherFoundation
import AetherRules
import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Darwin)
    import Darwin
#endif

/// aether-cli：开发调试命令行（docs/02 §3.1、docs/05 §8.2）。
let usage = """
    用法：aether-cli <命令> [参数]

    命令：
      check <配置> [--module <模块>]...
          校验配置（可叠加模块），输出诊断；有 error 时退出码为 1。
      match <配置> (--host <主机> | --url <URL> | --ip <地址>) [选项]
          逐条追踪规则匹配并给出策略链。选项：
            --port <端口>  --protocol tcp|udp|http|https|quic  --user-agent <UA>  --in-port <端口>
            --ssid <SSID>  --network wifi|cellular|wired
            --resolve <主机>=<地址>[,<地址>]   离线解析表（可重复）；未给出的主机视为解析失败
            --resource <URL>=<本地文件>         用本地文件代替远程规则集 / 域名集（可重复）
            --select <组>=<成员>               select 组的选择（可重复）
            --module <模块>
          本地路径的规则集相对配置文件所在目录读取。
      render <配置> [--redact]
          重新渲染配置；--redact 遮盖密码、UUID、令牌等敏感值。
      run --profile <文件> --socks <地址> --http <地址>（M2）
    """

struct CLIError: Error {
    let message: String
}

func readSource(_ path: String) throws -> ProfileInspector.Source {
    let url = URL(fileURLWithPath: path)
    guard let data = FileManager.default.contents(atPath: url.path) else {
        throw CLIError(message: "无法读取 \(path)")
    }
    return ProfileInspector.Source(name: url.lastPathComponent, text: String(decoding: data, as: UTF8.self))
}

func run(_ arguments: [String]) throws -> Int32 {
    guard let command = arguments.first else {
        print(usage)
        return 64
    }
    var rest = Array(arguments.dropFirst())
    func takeValue(_ flag: String) throws -> String {
        guard let index = rest.firstIndex(of: flag) else { throw CLIError(message: "缺少 \(flag)") }
        guard index + 1 < rest.count else { throw CLIError(message: "\(flag) 需要一个值") }
        let value = rest[index + 1]
        rest.removeSubrange(index...(index + 1))
        return value
    }
    func takeAll(_ flag: String) throws -> [String] {
        var values: [String] = []
        while rest.contains(flag) { values.append(try takeValue(flag)) }
        return values
    }
    func takeFlag(_ flag: String) -> Bool {
        guard let index = rest.firstIndex(of: flag) else { return false }
        rest.remove(at: index)
        return true
    }
    func pair(_ text: String) throws -> (String, String) {
        guard let equals = text.firstIndex(of: "=") else { throw CLIError(message: "\(text) 应为 键=值") }
        return (String(text[..<equals]), String(text[text.index(after: equals)...]))
    }

    switch command {
    case "--help", "-h", "help":
        print(usage)
        return 0
    case "check":
        let modules = try takeAll("--module").map(readSource)
        guard rest.count == 1 else { throw CLIError(message: "check 需要一个配置文件") }
        let result = ProfileInspector.check(try readSource(rest[0]), modules: modules)
        print(result.output, terminator: "")
        return result.exitCode
    case "render":
        let redact = takeFlag("--redact")
        guard rest.count == 1 else { throw CLIError(message: "render 需要一个配置文件") }
        print(ProfileInspector.render(try readSource(rest[0]), redact: redact), terminator: "")
        return 0
    case "match":
        let modules = try takeAll("--module").map(readSource)
        var target: String?
        for flag in ["--host", "--url", "--ip"] where rest.contains(flag) {
            target = try takeValue(flag)
        }
        guard let target else { throw CLIError(message: "match 需要 --host、--url 或 --ip") }
        var query = ProfileInspector.MatchQuery(target: target)
        if rest.contains("--port") {
            guard let port = UInt16(try takeValue("--port")) else { throw CLIError(message: "无效端口") }
            query.port = port
        }
        if rest.contains("--in-port") {
            guard let port = UInt16(try takeValue("--in-port")) else { throw CLIError(message: "无效端口") }
            query.inboundPort = port
        }
        if rest.contains("--protocol") {
            switch try takeValue("--protocol").lowercased() {
            case "tcp": query.transport = .tcp
            case "udp": query.transport = .udp
            case "http": query.appProtocol = .http
            case "https": query.appProtocol = .https
            case "quic":
                query.transport = .udp
                query.appProtocol = .quic
            default: throw CLIError(message: "无效协议")
            }
        }
        if rest.contains("--user-agent") { query.userAgent = try takeValue("--user-agent") }
        if rest.contains("--ssid") { query.network.ssid = try takeValue("--ssid") }
        if rest.contains("--network") {
            guard let type = SubnetCondition.InterfaceType(rawValue: try takeValue("--network").uppercased()) else {
                throw CLIError(message: "无效网络类型")
            }
            query.network.interfaceType = type
        }
        for item in try takeAll("--resolve") {
            let (host, addresses) = try pair(item)
            let parsed = addresses.split(separator: ",").compactMap { IPAddress($0) }
            guard let name = Hostname(host), !parsed.isEmpty else { throw CLIError(message: "无效解析 \(item)") }
            query.resolutions[name.value] = parsed
        }
        for item in try takeAll("--select") {
            let (group, member) = try pair(item)
            query.selections[group] = member
        }
        var resources: [String: String] = [:]
        for item in try takeAll("--resource") {
            let (location, path) = try pair(item)
            resources[location] = try readSource(path).text
        }
        guard rest.count == 1 else { throw CLIError(message: "match 需要一个配置文件") }
        let profilePath = rest[0]
        let profile = try readSource(profilePath)
        // 本地规则集：相对配置文件所在目录。
        let directory = URL(fileURLWithPath: profilePath).deletingLastPathComponent()
        let resolved = ProfileInspector.resolve(profile, modules: modules)
        for resource in resolved.externalResources where !resource.isRemote && resources[resource.url] == nil {
            if let data = FileManager.default.contents(atPath: directory.appendingPathComponent(resource.url).path) {
                resources[resource.url] = String(decoding: data, as: UTF8.self)
            }
        }
        print(ProfileInspector.match(profile, modules: modules, query: query, resources: resources), terminator: "")
        return 0
    default:
        throw CLIError(message: "未知命令：\(command)")
    }
}

do {
    exit(try run(Array(CommandLine.arguments.dropFirst())))
} catch let error as CLIError {
    FileHandle.standardError.write(Data("aether-cli: \(error.message)\n\n\(usage)\n".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("aether-cli: \(error)\n".utf8))
    exit(1)
}
