import Testing

@testable import AetherStore

@Test func moduleIdentity() {
    #expect(AetherStoreModule.name == "AetherStore")
    #expect(AetherStoreModule.dependencies.count == 1)
}
