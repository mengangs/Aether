import AetherIPC
import Foundation
import NetworkExtension
import Testing

@testable import AetherControl

@Test(arguments: [
    (NEVPNStatus.invalid, TunnelConnectionState.invalid),
    (.disconnected, .disconnected),
    (.connecting, .connecting),
    (.reasserting, .reasserting),
    (.disconnecting, .disconnecting),
])
func mapsVPNStatus(_ status: NEVPNStatus, _ expected: TunnelConnectionState) {
    #expect(TunnelController.state(for: status, connectedDate: nil) == expected)
}

@Test func connectedCarriesDate() {
    let date = Date(timeIntervalSince1970: 100)
    #expect(TunnelController.state(for: .connected, connectedDate: date) == .connected(since: date))
}

@Test func describesPermissionDenial() {
    let error = NSError(domain: NEVPNErrorDomain, code: NEVPNError.Code.configurationReadWriteFailed.rawValue)
    let described = TunnelController.describe(error)
    #expect(described.suggestsReinstall)
    #expect(described.code == nil)
}

@Test func describesTunnelStartFailureWithCode() {
    let error = NSError(
        domain: "Aether", code: 1, userInfo: ["AetherErrorCode": "STO-001", NSLocalizedDescriptionKey: "STO-001: x"])
    #expect(TunnelController.describe(error).code == "STO-001")
}

@Test func mockClientReportsNotRunning() async {
    await #expect(throws: (any Error).self) {
        try await MockTunnelClient.notRunning.status()
    }
}

@Test func mockClientFixturesPageAndFail() async throws {
    let client = MockTunnelClient.running
    let recent = try await client.requests(kind: .recent, sinceID: nil, limit: 1)
    #expect(recent.records.map(\.id) == [1] && recent.next == 1)
    let next = try await client.requests(kind: .recent, sinceID: recent.next, limit: 10)
    #expect(next.records.map(\.id) == [2])
    #expect(try await client.requests(kind: .active, sinceID: nil, limit: 10).records.map(\.id) == [3])
    #expect(try await MockTunnelClient.empty.policies().groups.isEmpty)
    await #expect(throws: IPCError.self) { try await MockTunnelClient.failing().traffic() }
}
