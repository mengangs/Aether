import AetherFoundation
import AetherTestSupport
import Foundation
import Testing

@testable import AetherIPC

struct IPCMessageTests {
    static let date = Date(timeIntervalSince1970: 1_793_347_200)

    static var sampleStatus: TunnelStatus {
        TunnelStatus(
            state: .running,
            since: date,
            updatedAt: date.addingTimeInterval(330),
            profile: ProfileSummary(id: "6F1C", name: "Main", revision: "sha256:abc"),
            outboundMode: .rule,
            globalPolicy: "Proxy",
            network: NetworkSummary(interfaceType: "wifi", ssid: nil, revision: 12),
            traffic: TrafficSummary(
                upBps: 1234, downBps: 56789, sessionUpBytes: 1_048_576, sessionDownBytes: 73_400_320),
            primaryGroups: [PolicyGroupSummary(name: "Proxy", current: "HK-01", latencyMs: 120)],
            alerts: [StatusAlert(code: "MITM-002", severity: .warning)]
        )
    }

    @Test func requestEncodesCommandAsTypeAndParams() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let data = try IPCCodec.encode(IPCRequest(id: id, command: .getStatus))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == #"{"command":{"type":"getStatus"},"id":"00000000-0000-0000-0000-000000000001","version":1}"#)
        #expect(try IPCCodec.decode(IPCRequest.self, from: data) == IPCRequest(id: id, command: .getStatus))
    }

    @Test func statusRoundTripsWithDocumentedKeys() throws {
        let response = IPCResponse(id: UUID(), outcome: .success(.status(Self.sampleStatus)))
        let data = try IPCCodec.encode(response)
        #expect(try IPCCodec.decode(IPCResponse.self, from: data) == response)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let success = try #require((object["outcome"] as? [String: Any])?["success"] as? [String: Any])
        let status = try #require(success["value"] as? [String: Any])
        for key in [
            "schemaVersion", "writer", "state", "since", "updatedAt", "profile", "outboundMode", "globalPolicy",
            "features", "network", "traffic", "primaryGroups", "alerts",
        ] {
            #expect(status[key] != nil, "missing \(key)")
        }
        #expect(status["since"] as? String == "2026-10-30T08:00:00Z")
        #expect(status["state"] as? String == "running")
    }

    @Test func failureRoundTrips() throws {
        let response = IPCResponse(
            id: UUID(),
            outcome: .failure(IPCError(code: .ipcInvalidArgument, message: "no such group", details: ["group": "X"])))
        let data = try IPCCodec.encode(response)
        #expect(try IPCCodec.decode(IPCResponse.self, from: data) == response)
        #expect(String(decoding: data, as: UTF8.self).contains(#""code":"IPC-011""#))
    }

    @Test func unknownCommandFailsToDecode() {
        let data = Data(
            #"{"version":1,"id":"00000000-0000-0000-0000-000000000002","command":{"type":"launchRockets"}}"#.utf8)
        #expect(throws: DecodingError.self) {
            try IPCCodec.decode(IPCRequest.self, from: data)
        }
        #expect(IPCCodec.envelope(of: data)?.version == 1)
    }

    @Test func oversizedPayloadIsIPC005() {
        let huge = String(repeating: "x", count: IPCProtocol.maxPayloadBytes)
        let response = IPCResponse(id: UUID(), outcome: .failure(IPCError(code: .ipcInvalidState, message: huge)))
        #expect(throws: IPCError.self) {
            try IPCCodec.encode(response)
        }
        do {
            _ = try IPCCodec.encode(response)
        } catch let error as IPCError {
            #expect(error.code == "IPC-005")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }
}

/// 可编程的假传输。
final class FakeTransport: IPCTransport, @unchecked Sendable {
    enum Behavior {
        case reply(@Sendable (Data) -> Data?)
        case fail(any Error)
        case hang
    }

    private let behavior: Locked<Behavior>

    init(_ behavior: Behavior) {
        self.behavior = Locked(behavior)
    }

    func send(_ message: Data) async throws -> Data? {
        switch behavior.current {
        case .reply(let make):
            return make(message)
        case .fail(let error):
            throw error
        case .hang:
            let waiter = OnceContinuation<Data?>()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { waiter.start($0) }
            } onCancel: {
                waiter.cancel()
            }
        }
    }
}

struct IPCClientTests {
    static func reply(_ outcome: IPCOutcome, version: Int = IPCProtocol.version) -> @Sendable (Data) -> Data? {
        { message in
            let request = try? IPCCodec.decode(IPCRequest.self, from: message)
            return try? IPCCodec.encode(IPCResponse(id: request?.id ?? UUID(), outcome: outcome, version: version))
        }
    }

    @Test func returnsStatus() async throws {
        let client = IPCClient(
            transport: FakeTransport(.reply(Self.reply(.success(.status(IPCMessageTests.sampleStatus))))))
        #expect(try await client.status() == IPCMessageTests.sampleStatus)
    }

    @Test func surfacesTunnelError() async {
        let client = IPCClient(
            transport: FakeTransport(.reply(Self.reply(.failure(IPCError(code: .ipcNoActiveBundle, message: "none"))))))
        await #expect(throws: IPCError(code: .ipcNoActiveBundle, message: "none")) {
            try await client.status()
        }
    }

    @Test func notRunningIsIPC001() async {
        let client = IPCClient(transport: FakeTransport(.fail(IPCError.tunnelNotRunning)))
        await #expect(throws: IPCError.tunnelNotRunning) {
            try await client.send(.getStatus)
        }
    }

    @Test func missingReplyIsIPC003() async {
        let client = IPCClient(transport: FakeTransport(.reply { _ in nil }))
        await #expect(throws: IPCError.noReply) {
            try await client.send(.getStatus)
        }
    }

    @Test func garbageReplyIsIPC003() async {
        let client = IPCClient(transport: FakeTransport(.reply { _ in Data("not json".utf8) }))
        do {
            _ = try await client.send(.getStatus)
            Issue.record("expected failure")
        } catch let error as IPCError {
            #expect(error.code == "IPC-003")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func newerTunnelVersionIsIPC002() async {
        let client = IPCClient(transport: FakeTransport(.reply(Self.reply(.success(.empty), version: 2))))
        do {
            _ = try await client.send(.getStatus)
            Issue.record("expected failure")
        } catch let error as IPCError {
            #expect(error.code == "IPC-002")
        } catch {
            Issue.record("unexpected \(error)")
        }
    }

    @Test func hangingTunnelTimesOutWithIPC004() async throws {
        let clock = ManualClock()
        let client = IPCClient(transport: FakeTransport(.hang), timeout: .seconds(5), clock: clock)
        let task = Task { try await client.send(.getStatus) }
        await clock.waitForSleepers()
        clock.advance(by: .seconds(4))
        #expect(clock.pendingSleeperCount == 1)
        clock.advance(by: .seconds(1))
        await #expect(throws: IPCError.timeout) {
            try await task.value
        }
    }
}
