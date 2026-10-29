import Testing

@testable import AetherRules

@Test func moduleIdentity() {
    #expect(AetherRulesModule.name == "AetherRules")
    #expect(AetherRulesModule.dependencies.count == 1)
}
