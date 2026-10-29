import Testing

@testable import AetherEngine

@Test func moduleIdentity() {
    #expect(AetherEngineModule.name == "AetherEngine")
    #expect(AetherEngineModule.dependencies.count == 6)
}
