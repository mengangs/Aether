import AetherIPC
import Testing

@testable import AetherKeychain

@Test func moduleIdentity() {
    #expect(AetherKeychainModule.name == "AetherKeychain")
    #expect(AetherKeychainModule.dependencies.count == 2)
}
