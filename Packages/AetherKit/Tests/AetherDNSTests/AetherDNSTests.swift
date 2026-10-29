import Testing

@testable import AetherDNS

@Test func moduleIdentity() {
    #expect(AetherDNSModule.name == "AetherDNS")
    #expect(AetherDNSModule.dependencies.count == 1)
}
