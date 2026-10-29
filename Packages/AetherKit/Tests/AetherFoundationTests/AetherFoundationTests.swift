import Testing

@testable import AetherFoundation

@Test func moduleIdentity() {
    #expect(AetherFoundationModule.name == "AetherFoundation")
    #expect(AetherFoundationModule.dependencies.count == 0)
}
