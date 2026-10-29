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
