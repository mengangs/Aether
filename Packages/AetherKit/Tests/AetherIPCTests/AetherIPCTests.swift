import Testing

@testable import AetherIPC

@Test func moduleIdentity() {
    #expect(AetherIPCModule.name == "AetherIPC")
    #expect(AetherIPCModule.dependencies.count == 1)
}
