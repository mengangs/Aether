import Testing

@testable import AetherProfile

@Test func moduleIdentity() {
    #expect(AetherProfileModule.name == "AetherProfile")
    #expect(AetherProfileModule.dependencies.count == 1)
}
