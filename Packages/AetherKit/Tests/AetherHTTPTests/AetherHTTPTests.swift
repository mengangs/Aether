import Testing

@testable import AetherHTTP

@Test func moduleIdentity() {
    #expect(AetherHTTPModule.name == "AetherHTTP")
    #expect(AetherHTTPModule.dependencies.count == 4)
}
