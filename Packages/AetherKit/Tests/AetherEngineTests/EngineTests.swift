import AetherFoundation
import AetherIPC
import AetherOutbound
import AetherProfile
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

@testable import AetherEngine

private func configuration(_ text: String) -> RuntimeConfiguration {
    let resolved = ProfileResolver.resolve(profileText: text, fileName: "engine.conf")
    return RuntimeConfiguration.compile(resolved, profileID: "test", profileName: "engine")
}

private func profile(rule: String, groups: String = "") -> String {
    """
    [General]
    dns-server = 192.0.2.53
    system-proxy = false

    [Proxy Group]
    \(groups)

    [Rule]
    \(rule)
    FINAL,DIRECT
    """
}

/// 经引擎的 SOCKS5 入站（无认证）连接目标。
private func connect(_ engine: Engine, to destination: Destination) async throws -> (any Channel, CollectingHandler) {
    let connector = SOCKS5Connector(
        name: "client", server: ProxyServer(host: "127.0.0.1", port: UInt16(engine.socks.port)), username: nil,
        password: nil, udpEnabled: false)
    let context = DialContext(
        flowID: FlowID(rawValue: 0), eventLoop: engine.eventLoop, deadline: .now() + .seconds(15),
        serverResolver: FixedResolver(), logger: Logger(label: "test"))
    let channel = try await connector.connect(to: destination, context: context).get()
    let collector = CollectingHandler()
    try await channel.eventLoop.submit {
        try channel.pipeline.syncOperations.addHandler(collector)
        try channel.syncOptions?.setOption(.autoRead, value: true)
        channel.read()
    }.get()
    return (channel, collector)
}

@Suite("Engine hot swap")
struct EngineTests {
    @Test("Reloading keeps existing flows on the old configuration and routes new flows with the new one")
    func hotSwap() async throws {
        let threads = EngineThreads()
        let echo = try await LoopbackTCPServer.start(group: threads.group) { channel in
            channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(EchoHandler()) }
        }
        var options = Engine.Options()
        options.socksCredentials = nil
        options.httpProxy = nil
        let engine = try await Engine.start(
            configuration: configuration(profile(rule: "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve")), options: options,
            threads: threads)
        let target = Destination.ip(IPAddress("127.0.0.1")!, port: UInt16(echo.port))

        let (existing, existingCollector) = try await connect(engine, to: target)
        try await existing.writeAndFlush(ByteBuffer(string: "before"))
        #expect(await Poll.until { String(decoding: existingCollector.bytes, as: UTF8.self) == "before" })

        try await engine.reload(configuration(profile(rule: "IP-CIDR,127.0.0.0/8,REJECT,no-resolve")))

        // 已有连接不受影响。
        try await existing.writeAndFlush(ByteBuffer(string: "+after"))
        #expect(await Poll.until { String(decoding: existingCollector.bytes, as: UTF8.self) == "before+after" })
        #expect(existing.isActive)

        // 新连接按新配置被拒绝。
        let (fresh, freshCollector) = try await connect(engine, to: target)
        try? await fresh.writeAndFlush(ByteBuffer(string: "x"))
        #expect(await Poll.until { freshCollector.receivedEOF })
        let records = try await engine.eventLoop.submit { engine.requests.recent }.get()
        #expect(records.last?.errorCode == "NET-022")

        try await existing.close()
        // 引擎停止时会关闭它的执行环境（与回显服务共用），所以先关回显服务。
        try await echo.close()
        await engine.stop()
    }

    @Test("Selections persist, survive a reload for same-name groups, and reset when the member disappears")
    func selections() async throws {
        let saved = NIOLockedValueBox<[[String: String]]>([])
        var options = Engine.Options()
        options.socksCredentials = nil
        options.httpProxy = nil
        options.persistSelections = { selection in saved.withLockedValue { $0.append(selection) } }
        let groups = "Main = select, DIRECT, REJECT\nOther = select, DIRECT, REJECT"
        let engine = try await Engine.start(
            configuration: configuration(profile(rule: "DOMAIN,a.example.com,Main", groups: groups)), options: options,
            selections: ["Main": "REJECT", "Gone": "DIRECT"])
        #expect(engine.policies.currentSelections == ["Main": "REJECT"])

        try await engine.selectPolicy(group: "Other", member: "REJECT")
        #expect(saved.withLockedValue { $0.last } == ["Main": "REJECT", "Other": "REJECT"])
        await #expect(throws: IPCError.self) { try await engine.selectPolicy(group: "Other", member: "Nope") }
        await #expect(throws: IPCError.self) { try await engine.selectPolicy(group: "Missing", member: "DIRECT") }

        // 新配置中 Main 仍有 REJECT，Other 的成员只剩 DIRECT：Main 保留，Other 重置。
        let newGroups = "Main = select, DIRECT, REJECT\nOther = select, DIRECT"
        try await engine.reload(configuration(profile(rule: "DOMAIN,a.example.com,Main", groups: newGroups)))
        #expect(engine.policies.currentSelections == ["Main": "REJECT"])
        #expect(saved.withLockedValue { $0.last } == ["Main": "REJECT"])

        try await engine.setOutboundMode(.global)
        await #expect(throws: IPCError.self) { try await engine.setGlobalPolicy("Missing") }
        try await engine.setGlobalPolicy("Main")
        let mode = try await engine.eventLoop.submit { (engine.router.outboundMode, engine.router.globalPolicy) }.get()
        #expect(mode.0 == .global && mode.1 == "Main")
        await engine.stop()
    }

    @Test("State files round-trip and keep a bounded number of profiles")
    func stateFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "aether-state-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? FileManager.default.removeItem(at: directory) }
        let container = SharedContainer(root: directory)
        let runtime = RuntimeStateFile(outboundMode: .global, globalPolicy: "Proxy")
        try JSONStateFile.write(runtime, to: container.runtimeStateFile)
        #expect(JSONStateFile.read(RuntimeStateFile.self, from: container.runtimeStateFile) == runtime)
        var selections = SelectionsFile()
        for index in 0..<70 {
            selections.set(["G": "M\(index)"], for: String(format: "profile-%03d", index))
        }
        #expect(selections.selections.count == SelectionsFile.profileLimit)
        #expect(selections.selections["profile-069"] == ["G": "M69"])
        try JSONStateFile.write(selections, to: container.selectionsFile)
        #expect(JSONStateFile.read(SelectionsFile.self, from: container.selectionsFile) == selections)
        #expect(JSONStateFile.read(SelectionsFile.self, from: directory.appendingPathComponent("missing.json")) == nil)
    }
}
