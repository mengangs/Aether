import Testing

@testable import AetherTunnelSupport

@Test func moduleIdentity() {
    #expect(AetherTunnelSupportModule.name == "AetherTunnelSupport")
    #expect(AetherTunnelSupportModule.dependencies.count == 1)
}
