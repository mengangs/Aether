import Testing

@testable import AetherControl

@Test func moduleIdentity() {
    #expect(AetherControlModule.name == "AetherControl")
    #expect(AetherControlModule.dependencies.count == 1)
}
