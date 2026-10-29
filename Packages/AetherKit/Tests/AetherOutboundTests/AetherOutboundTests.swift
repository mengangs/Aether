import Testing

@testable import AetherOutbound

@Test func moduleIdentity() {
    #expect(AetherOutboundModule.name == "AetherOutbound")
    #expect(AetherOutboundModule.dependencies.count == 2)
}
