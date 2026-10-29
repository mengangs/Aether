import Testing

@testable import AetherTunnelSupport

@Test func moduleIdentity() {
    #expect(AetherTunnelSupportModule.name == "AetherTunnelSupport")
    #expect(AetherTunnelSupportModule.dependencies.count == 2)
}

@Test func hevIsLinked() {
    #expect(HevBridge.entryPoints.count == 3)
}
