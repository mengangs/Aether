import Testing

@testable import AetherScript

@Test func moduleIdentity() {
    #expect(AetherScriptModule.name == "AetherScript")
    #expect(AetherScriptModule.dependencies.count == 1)
}
