import AetherFoundation
import Foundation
import Testing

@testable import AetherIPC

struct AppEnvironmentTests {
    static var valid: [String: Any] {
        [
            "AetherBundleIdentifierPrefix": "com.example.aether",
            "AetherAppGroupIdentifier": "group.com.example.aether",
            "AetherKeychainAccessGroup": "ABCDE12345.com.example.aether.shared",
            "AetherTunnelBundleIdentifier": "com.example.aether.tunnel",
            "AetherURLScheme": "aether",
        ]
    }

    @Test func readsAllKeys() throws {
        let environment = try AppEnvironment(infoDictionary: Self.valid)
        #expect(environment.bundleIdentifierPrefix == "com.example.aether")
        #expect(environment.appGroupIdentifier == "group.com.example.aether")
        #expect(environment.keychainAccessGroup == "ABCDE12345.com.example.aether.shared")
        #expect(environment.tunnelBundleIdentifier == "com.example.aether.tunnel")
        #expect(environment.urlScheme == "aether")
        #expect(environment.statusNotificationName == "com.example.aether.notify.status")
        #expect(environment.resourceRefreshTaskIdentifier == "com.example.aether.resources")
        #expect(environment.logbookNotificationName == "com.example.aether.notify.logbook")
    }

    @Test(arguments: AppEnvironment.InfoKey.allCases)
    func missingKeyIsReported(_ key: AppEnvironment.InfoKey) {
        var info = Self.valid
        info[key.rawValue] = nil
        #expect(throws: AppEnvironmentError.missingKey(key.rawValue)) {
            try AppEnvironment(infoDictionary: info)
        }
        #expect(AppEnvironmentError.missingKey(key.rawValue).code == "IPC-020")
    }

    @Test(arguments: [
        ("AetherAppGroupIdentifier", "$(AETHER_APP_GROUP)"),
        ("AetherAppGroupIdentifier", ""),
        ("AetherTunnelBundleIdentifier", "com.example.aether tunnel"),
        ("AetherBundleIdentifierPrefix", ".com.example"),
        ("AetherURLScheme", "1aether"),
        ("AetherKeychainAccessGroup", "..."),
    ])
    func invalidValueIsReported(_ key: String, _ value: String) {
        var info = Self.valid
        info[key] = value
        #expect(throws: AppEnvironmentError.invalidValue(key: key, value: value)) {
            try AppEnvironment(infoDictionary: info)
        }
    }

    @Test func nonStringValueIsInvalid() {
        var info = Self.valid
        info["AetherURLScheme"] = 42
        #expect(throws: AppEnvironmentError.self) {
            try AppEnvironment(infoDictionary: info)
        }
    }

    @Test func keychainGroupWithoutTeamPrefixIsAccepted() throws {
        var info = Self.valid
        info["AetherKeychainAccessGroup"] = ".com.example.aether.shared"
        let environment = try AppEnvironment(infoDictionary: info)
        #expect(AppEnvironment.teamPrefix(of: environment.keychainAccessGroup) == "")
    }

    // MARK: Keychain 访问组校正

    @Test func matchingPrefixIsKept() throws {
        let environment = try AppEnvironment(infoDictionary: Self.valid)
        let (resolved, resolution) = environment.resolvingKeychainAccessGroup(probed: "ABCDE12345.com.example.aether")
        #expect(resolution == .matched)
        #expect(resolved == environment)
    }

    @Test func mismatchedPrefixUsesProbe() throws {
        let environment = try AppEnvironment(infoDictionary: Self.valid)
        let (resolved, resolution) = environment.resolvingKeychainAccessGroup(probed: "ZZZZZ99999.anything.else")
        #expect(resolved.keychainAccessGroup == "ZZZZZ99999.com.example.aether.shared")
        #expect(
            resolution == .corrected(from: "ABCDE12345.com.example.aether.shared", to: resolved.keychainAccessGroup))
        #expect(resolved.appGroupIdentifier == environment.appGroupIdentifier)
    }

    @Test func emptyPrefixFromUnsignedBuildIsFilledIn() throws {
        var info = Self.valid
        info["AetherKeychainAccessGroup"] = ".com.example.aether.shared"
        let environment = try AppEnvironment(infoDictionary: info)
        let (resolved, resolution) = environment.resolvingKeychainAccessGroup(
            probed: "TEAM123456.com.example.aether.shared")
        #expect(resolved.keychainAccessGroup == "TEAM123456.com.example.aether.shared")
        #expect(
            resolution == .corrected(from: ".com.example.aether.shared", to: "TEAM123456.com.example.aether.shared"))
    }

    @Test(arguments: [nil, "", "nodots", ".leadingdot"] as [String?])
    func failedProbeKeepsConfiguredValue(_ probed: String?) throws {
        let environment = try AppEnvironment(infoDictionary: Self.valid)
        let (resolved, resolution) = environment.resolvingKeychainAccessGroup(probed: probed)
        #expect(resolution == .probeFailed)
        #expect(resolved == environment)
    }
}

struct SharedContainerTests {
    @Test func locatesAetherDirectory() throws {
        let container = try SharedContainer.locate(appGroupIdentifier: "group.com.example.aether") { identifier in
            #expect(identifier == "group.com.example.aether")
            return URL(fileURLWithPath: "/tmp/group", isDirectory: true)
        }
        #expect(container.root.path == "/tmp/group/Aether")
        #expect(container.logs.path == "/tmp/group/Aether/Logs")
        #expect(container.activeBundlePointer.path == "/tmp/group/Aether/active.json")
        #expect(container.tunnelStatusFile.path == "/tmp/group/Aether/State/tunnel-status.json")
    }

    @Test func missingContainerIsSTO001() {
        #expect(throws: SharedContainerError.appGroupUnavailable("group.missing")) {
            try SharedContainer.locate(appGroupIdentifier: "group.missing") { _ in nil }
        }
        #expect(SharedContainerError.appGroupUnavailable("x").code == "STO-001")
    }
}
