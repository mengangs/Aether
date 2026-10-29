import Testing

@testable import AetherCertificates

@Test func moduleIdentity() {
    #expect(AetherCertificatesModule.name == "AetherCertificates")
    #expect(AetherCertificatesModule.dependencies.count == 1)
}
