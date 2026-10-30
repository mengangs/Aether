import AetherFoundation
import AetherIPC
import AetherStore
import Foundation
import NIOConcurrencyHelpers
import Testing

@testable import AetherEngine

private let baseProfile = """
    [General]
    dns-server = 192.0.2.53

    [Proxy]
    A = socks5, 192.0.2.10, 1080
    B = http, 192.0.2.11, 8080

    [Proxy Group]
    Main = select, A, B, DIRECT
    Auto = url-test, A, B, url=http://www.example.com/

    [Rule]
    FINAL,Main
    """

/// 临时 App Group 容器与写入运行包的工具。
private struct ContainerFixture {
    let container: SharedContainer

    init() {
        container = SharedContainer(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("aether-runtime-\(UUID().uuidString)"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: container.root)
    }

    /// 写入运行包并让 `active.json` 指向它。
    func commit(profile: String, revision: String, modules: [(name: String, text: String)] = []) throws {
        let name = String(revision.suffix(16))
        let directory = container.bundles.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("modules"), withIntermediateDirectories: true)
        try Data(profile.utf8).write(to: directory.appendingPathComponent("profile.conf"))
        var entries: [BundleManifest.Module] = []
        for (index, module) in modules.enumerated() {
            let file = "modules/0\(index + 1)-m.amodule"
            try Data(module.text.utf8).write(to: directory.appendingPathComponent(file))
            entries.append(.init(id: "M\(index)", name: module.name, file: file))
        }
        try JSONStateFile.write(
            BundleManifest(
                revision: revision, profileID: "P1", profileName: "Main", committedAt: Date(timeIntervalSince1970: 0),
                appVersion: "test", modules: entries),
            to: directory.appendingPathComponent("manifest.json"))
        try JSONStateFile.write(
            ActiveBundlePointer(
                revision: revision, bundle: "Bundles/\(name)", committedAt: Date(timeIntervalSince1970: 0)),
            to: container.activeBundlePointer)
    }

    func runtime(notifications: NIOLockedValueBox<[String]>, reasserts: NIOLockedValueBox<[(Int, Bool)]>)
        -> TunnelRuntime
    {
        var hooks = TunnelRuntime.Hooks()
        hooks.httpProxyAddress = ("127.0.0.1", 0)
        hooks.dnsUpstreams = { _ in LoopbackDNSUpstream() }
        hooks.notify = { name in notifications.withLockedValue { $0.append(name) } }
        hooks.reassert = { settings, _, restartHev in
            reasserts.withLockedValue { $0.append((settings.mtu, restartHev)) }
        }
        hooks.memory = { (40 * 1024 * 1024, 10 * 1024 * 1024) }
        hooks.systemDNSServers = { [IPAddress("192.0.2.53")!] }
        return TunnelRuntime(container: container, notificationPrefix: "com.example.aether", hooks: hooks)
    }

    var status: TunnelStatus? { JSONStateFile.read(TunnelStatus.self, from: container.tunnelStatusFile) }
}

@Suite("Tunnel runtime (06 §2, 10 §2–§3)")
struct TunnelRuntimeTests {
    @Test("Without an active bundle start fails with IPC-010 and the snapshot says failed")
    func noBundle() async throws {
        let fixture = ContainerFixture()
        defer { fixture.remove() }
        let runtime = fixture.runtime(notifications: .init([]), reasserts: .init([]))
        await #expect(throws: IPCError.self) { _ = try await runtime.start() }
        do {
            _ = try await runtime.start()
        } catch let error as IPCError {
            #expect(error.code == .ipcNoActiveBundle)
        }
        #expect(fixture.status?.state == .failed)
        #expect(fixture.status?.lastError?.code == .ipcNoActiveBundle)
    }

    @Test("A profile with errors fails the start with its CFG code and a diagnostics summary")
    func brokenProfile() async throws {
        let fixture = ContainerFixture()
        defer { fixture.remove() }
        try fixture.commit(profile: "[Rule]\nFINAL,Missing", revision: "sha256:broken000000000001")
        let runtime = fixture.runtime(notifications: .init([]), reasserts: .init([]))
        do {
            _ = try await runtime.start()
            Issue.record("expected a configuration error")
        } catch let error as IPCError {
            #expect(error.code.namespace == .cfg)
            #expect(error.details?["diagnostics"]?.contains("Missing") == true)
        }
        #expect(fixture.status?.state == .failed)
    }

    @Test("Start restores state, the M2 commands work, reload swaps or rejects, and stop persists")
    func lifecycle() async throws {
        let fixture = ContainerFixture()
        defer { fixture.remove() }
        let container = fixture.container
        try fixture.commit(
            profile: baseProfile, revision: "sha256:first00000000000001",
            modules: [("Sample", "#!name=Sample\n[Rule]\nDOMAIN,mod.example.com,DIRECT")])
        var runtimeState = RuntimeStateFile(outboundMode: .global, globalPolicy: "Main")
        runtimeState.features.capture = false
        try JSONStateFile.write(runtimeState, to: container.runtimeStateFile)
        try JSONStateFile.write(SelectionsFile(selections: ["P1": ["Main": "B"]]), to: container.selectionsFile)
        let notifications = NIOLockedValueBox<[String]>([])
        let reasserts = NIOLockedValueBox<[(Int, Bool)]>([])
        let runtime = fixture.runtime(notifications: notifications, reasserts: reasserts)

        let started = try await runtime.start()
        #expect(started.settings.mtu == 1500 && started.settings.dns?.servers == ["198.18.0.2"])
        #expect(started.hev.socksPort > 0 && started.hev.username.count == 32)
        await runtime.didStart()
        #expect(fixture.status?.state == .running)
        #expect(fixture.status?.profile?.revision == "sha256:first00000000000001")
        #expect(notifications.withLockedValue { $0 }.contains("com.example.aether.notify.status"))

        guard case .status(let status) = try await runtime.handle(.getStatus) else {
            Issue.record("expected status")
            return
        }
        #expect(status.state == .running && status.outboundMode == .global && status.globalPolicy == "Main")
        #expect(status.primaryGroups == [PolicyGroupSummary(name: "Main", current: "B")])

        guard case .policies(let policies) = try await runtime.handle(.listPolicies) else {
            Issue.record("expected policies")
            return
        }
        #expect(policies.groups.map(\.name) == ["Main", "Auto"])
        #expect(policies.groups.first?.selected == "B" && policies.groups.first?.members == ["A", "B", "DIRECT"])
        #expect(policies.groups.last?.note?.contains("M3-07") == true)
        #expect(policies.nodes.map(\.name) == ["A", "B"] && policies.nodes.allSatisfy(\.available))

        #expect(try await runtime.handle(.setOutboundMode(.rule)) == .empty)
        #expect(JSONStateFile.read(RuntimeStateFile.self, from: container.runtimeStateFile)?.outboundMode == .rule)
        #expect(try await runtime.handle(.selectPolicy(group: "Main", policy: "A")) == .empty)
        #expect(
            JSONStateFile.read(SelectionsFile.self, from: container.selectionsFile)?.selections["P1"]?["Main"] == "A")
        do {
            _ = try await runtime.handle(.selectPolicy(group: "Main", policy: "Nope"))
            Issue.record("expected IPC-011")
        } catch let error as IPCError {
            #expect(error.code == .ipcInvalidArgument)
        }
        guard
            case .requests(let page) = try await runtime.handle(.getRequests(kind: .recent, sinceID: nil, limit: 1000))
        else {
            Issue.record("expected requests")
            return
        }
        #expect(page.records.isEmpty && page.next == nil)
        guard case .traffic(let traffic) = try await runtime.handle(.getTraffic) else {
            Issue.record("expected traffic")
            return
        }
        #expect(traffic.sessionUpBytes == 0 && traffic.buckets.isEmpty)
        guard case .memoryInfo(let memory) = try await runtime.handle(.getMemoryInfo) else {
            Issue.record("expected memory info")
            return
        }
        #expect(memory.footprintBytes == 40 * 1024 * 1024 && memory.components["tcpFlows"] == 0)
        #expect(memory.systemDNSServers == ["192.0.2.53"])

        // 重载：规则变化不重新应用网络设置；MTU 变化重新应用并重启 hev。
        try fixture.commit(
            profile: baseProfile + "\nDOMAIN,new.example.com,DIRECT", revision: "sha256:second0000000000002")
        guard
            case .reload(let same) = try await runtime.handle(
                .reloadProfile(expectedRevision: "sha256:second0000000000002"))
        else {
            Issue.record("expected reload")
            return
        }
        #expect(same.errorCount == 0 && !same.reasserted)
        #expect(fixture.status?.profile?.revision == "sha256:second0000000000002")
        try fixture.commit(
            profile: baseProfile.replacingOccurrences(of: "[General]", with: "[General]\ntun-mtu = 1400"),
            revision: "sha256:third00000000000003")
        let mtu = try await runtime.reload(expectedRevision: nil)
        #expect(mtu.reasserted)
        #expect(
            reasserts.withLockedValue { $0.map(\.0) } == [1400] && reasserts.withLockedValue { $0.first?.1 } == true)
        // 修订号不符：IPC-012；有错误的配置：返回诊断并保留旧配置。
        do {
            _ = try await runtime.reload(expectedRevision: "sha256:other")
            Issue.record("expected IPC-012")
        } catch let error as IPCError {
            #expect(error.code == .ipcInvalidState)
        }
        try fixture.commit(profile: "[Rule]\nFINAL,Missing", revision: "sha256:broken000000000004")
        let rejected = try await runtime.reload(expectedRevision: nil)
        #expect(rejected.errorCount > 0 && rejected.diagnostics.first?.severity == "error")
        #expect(fixture.status?.profile?.revision == "sha256:third00000000000003")
        #expect(await runtime.state == .running)

        await runtime.handleMemoryPressure(.critical)
        await runtime.maintenance()
        await runtime.stop(reason: "test")
        #expect(fixture.status?.state == .idle)
        #expect(FileManager.default.fileExists(atPath: container.fakeIPSnapshotFile.path))
        await #expect(throws: IPCError.self) { _ = try await runtime.handle(.listPolicies) }

        let database = try AetherDatabase.open(directory: container.database)
        let logbook = try await database.recentLogbook()
        #expect(logbook.contains { $0.category == .memory && $0.code == "NET-041" })
        #expect(logbook.contains { $0.message.contains("Tunnel stopped") })
        #expect(logbook.contains { $0.category == .profile && $0.message.contains("Reload rejected") })
        #expect(notifications.withLockedValue { $0 }.contains("com.example.aether.notify.logbook"))
    }
}
