import Testing

@testable import AetherScriptCore

@Test func moduleIdentity() {
    #expect(AetherScriptCoreModule.name == "AetherScriptCore")
    #expect(AetherScriptCoreModule.dependencies.count == 1)
}
