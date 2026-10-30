import AetherFoundation
import Foundation
import Testing

@testable import AetherIPC

@Suite("M2 IPC commands and payloads (10 §2.2)")
struct IPCCommandsTests {
    @Test(
        "Every command round-trips with its parameters",
        arguments: [
            IPCCommand.getStatus, .getMemoryInfo, .reloadProfile(expectedRevision: "sha256:abc"),
            .reloadProfile(expectedRevision: nil), .setOutboundMode(.direct), .setGlobalPolicy("Proxy"), .listPolicies,
            .selectPolicy(group: "Main", policy: "HK"), .getTraffic,
            .getRequests(kind: .active, sinceID: 41, limit: 50), .getRequests(kind: .recent, sinceID: nil, limit: 200),
        ])
    func commandRoundTrip(_ command: IPCCommand) throws {
        let request = IPCRequest(command: command)
        #expect(try IPCCodec.decode(IPCRequest.self, from: IPCCodec.encode(request)) == request)
    }

    @Test("Command parameters use the documented field names")
    func commandShape() throws {
        let data = try IPCCodec.encode(IPCRequest(command: .selectPolicy(group: "Main", policy: "HK")))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains(#""type":"selectPolicy""#))
        #expect(text.contains(#""params":{"group":"Main","policy":"HK"}"#))
        let legacy = Data(
            #"{"version":1,"id":"00000000-0000-0000-0000-000000000001","command":{"type":"reloadProfile"}}"#.utf8)
        #expect(try IPCCodec.decode(IPCRequest.self, from: legacy).command == .reloadProfile(expectedRevision: nil))
    }

    @Test("Every payload round-trips")
    func payloadRoundTrip() throws {
        let record = RequestRecord(
            id: 7, startedAt: Date(timeIntervalSince1970: 1), inbound: .tun, transport: .udp,
            destination: "198.18.0.5:443")
        let payloads: [IPCPayload] = [
            .memoryInfo(
                MemoryInfo(
                    footprintBytes: 1 << 40, availableBytes: nil, components: ["tcpFlows": 3],
                    hev: HevStatisticsSummary(txPackets: 1, txBytes: 2, rxPackets: 3, rxBytes: UInt64.max))),
            .reload(
                ReloadResult(
                    revision: "sha256:x", errorCount: 1, warningCount: 0,
                    diagnostics: [
                        DiagnosticSummary(code: "CFG-020", severity: "error", file: "Main", line: 3, message: "m")
                    ], reasserted: false)),
            .policies(
                PolicyList(
                    groups: [
                        .init(name: "Main", type: "select", members: ["A"], selected: "A", hidden: false, note: nil)
                    ],
                    nodes: [.init(name: "A", type: "ss", supportsUDP: true, available: false, unavailableReason: "M3")])
            ),
            .traffic(
                TrafficReport(
                    sessionUpBytes: 5, sessionDownBytes: 6,
                    buckets: [.init(policy: "DIRECT", interface: "wifi", up: 5, down: 6)],
                    samples: [.init(at: Date(timeIntervalSince1970: 2), up: 1, down: 2)])),
            .requests(RequestPage(records: [record], next: 7)),
        ]
        for payload in payloads {
            let response = IPCResponse(id: UUID(), outcome: .success(payload))
            #expect(try IPCCodec.decode(IPCResponse.self, from: IPCCodec.encode(response)) == response)
        }
    }
}

@Suite("Run bundles (11 §6)")
struct RunBundleTests {
    private func container() -> SharedContainer {
        SharedContainer(root: FileManager.default.temporaryDirectory.appendingPathComponent("aether-bundle-\(UUID())"))
    }

    @Test("A committed bundle loads with its modules in manifest order")
    func load() throws {
        let container = container()
        defer { try? FileManager.default.removeItem(at: container.root) }
        let directory = container.bundles.appendingPathComponent("0123456789abcdef")
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("modules"), withIntermediateDirectories: true)
        try Data("[Rule]\nFINAL,DIRECT".utf8).write(to: directory.appendingPathComponent("profile.conf"))
        try Data("#!name=Two".utf8).write(to: directory.appendingPathComponent("modules/02-b.amodule"))
        try Data("#!name=One".utf8).write(to: directory.appendingPathComponent("modules/01-a.amodule"))
        try JSONStateFile.write(
            BundleManifest(
                revision: "sha256:0123456789abcdef", profileID: "P", profileName: "Main",
                committedAt: Date(timeIntervalSince1970: 0), appVersion: "0.3.0 (1)",
                modules: [
                    .init(id: "a", name: "One", file: "modules/01-a.amodule"),
                    .init(id: "b", name: "Two", file: "modules/02-b.amodule"),
                ]),
            to: directory.appendingPathComponent("manifest.json"))
        try JSONStateFile.write(
            ActiveBundlePointer(
                revision: "sha256:0123456789abcdef", bundle: "Bundles/0123456789abcdef",
                committedAt: Date(timeIntervalSince1970: 0)),
            to: container.activeBundlePointer)

        let bundle = try RunBundle.loadActive(from: container)
        #expect(bundle.manifest.profileName == "Main")
        #expect(bundle.profileText == "[Rule]\nFINAL,DIRECT")
        #expect(bundle.modules.map(\.name) == ["One", "Two"])
        #expect(bundle.modules.map(\.text) == ["#!name=One", "#!name=Two"])
    }

    @Test("Missing pointers and paths that leave the container fail with IPC-010")
    func invalid() throws {
        let container = container()
        defer { try? FileManager.default.removeItem(at: container.root) }
        #expect(
            throws: IPCError(code: .ipcNoActiveBundle, message: "No active bundle (active.json missing or unreadable)")
        ) {
            try RunBundle.loadActive(from: container)
        }
        for path in ["../outside", "/etc", "Bundles/../../x", ""] {
            #expect(throws: IPCError.self) { try RunBundle.resolve(path, under: container.root) }
        }
        #expect(try RunBundle.resolve("Bundles/abc", under: container.root).lastPathComponent == "abc")
    }
}

@Suite("Profile library and bundle commit (11 §3, §6)")
struct ProfileLibraryTests {
    private let now = Date(timeIntervalSince1970: 1_793_361_600)

    @Test("Profiles are added, updated, renamed, committed with their modules and protected while current")
    func lifecycle() throws {
        let container = SharedContainer(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("aether-library-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: container.root) }
        let library = ProfileLibrary(container: container)
        #expect(library.profiles().isEmpty)
        let main = try library.addProfile(
            name: "Main", text: "[Rule]\nFINAL,DIRECT", source: .imported(url: "https://example.com/a.conf"),
            revision: "sha256:aa", now: now)
        let spare = try library.addProfile(name: "Spare", text: "x", source: .local, revision: "sha256:bb", now: now)
        #expect(library.profiles().map(\.name) == ["Main", "Spare"])
        #expect(try library.text(of: main) == "[Rule]\nFINAL,DIRECT")
        try library.updateProfile(main.id, text: "[Rule]\nFINAL,REJECT", revision: "sha256:cc", now: now + 60)
        try library.renameProfile(main.id, to: "Primary")
        let updated = try #require(library.profiles().first)
        #expect(updated.name == "Primary" && updated.revision == "sha256:cc" && updated.updatedAt == now + 60)
        #expect(updated.source == .imported(url: "https://example.com/a.conf"))

        let module = ModuleEntry(name: "Quick Rules", enabled: true, updatedAt: now)
        try RunBundle.commit(
            profile: updated, profileText: try library.text(of: updated),
            modules: [(module, "#!name=Quick Rules\n[Rule]\nDOMAIN,example.org,DIRECT")],
            revision: "sha256:0123456789abcdef0123", appVersion: "0.3.0 (1)", now: now, container: container)
        let bundle = try RunBundle.loadActive(from: container)
        #expect(bundle.manifest.profileID == main.id.uuidString && bundle.manifest.profileName == "Primary")
        #expect(bundle.profileText == "[Rule]\nFINAL,REJECT")
        #expect(bundle.modules.map(\.name) == ["Quick Rules"])
        #expect(bundle.directory.lastPathComponent == "0123456789abcdef")
        #expect(RunBundle.activeManifest(in: container)?.revision == "sha256:0123456789abcdef0123")

        #expect(throws: IPCError.self) { try library.removeProfile(main.id) }
        try library.removeProfile(spare.id)
        #expect(library.profiles().map(\.id) == [main.id])
        #expect(throws: IPCError.self) {
            try library.addProfile(
                name: "Huge", text: String(repeating: "x", count: ProfileLibrary.maxTextBytes + 1), source: .local,
                revision: "sha256:dd", now: now)
        }
    }

    @Test("Only the three most recent bundle directories are kept")
    func retention() throws {
        let container = SharedContainer(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("aether-retention-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: container.root) }
        let profile = ProfileEntry(name: "Main", source: .local, createdAt: now, updatedAt: now, revision: "r")
        for index in 1...5 {
            try RunBundle.commit(
                profile: profile, profileText: "[Rule]\nFINAL,DIRECT", modules: [],
                revision: "sha256:\(index)000000000000000\(index)", appVersion: "t", now: now, container: container)
            // 把刚提交的目录的修改时间拨到过去（越早提交越旧），使先后顺序与真实时钟无关。
            let directory = container.bundles.appendingPathComponent("\(index)000000000000000")
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(index) * 1000)], ofItemAtPath: directory.path)
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: container.bundles.path).sorted()
        #expect(names == ["3000000000000000", "4000000000000000", "5000000000000000"])
    }
}
