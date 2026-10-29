// swift-tools-version: 6.0
// AetherKit：Aether 的全部业务逻辑。模块清单与依赖方向见 docs/02-architecture.md §3，
// 平台条件见 docs/03-project-setup.md §5.4。
import PackageDescription

// MARK: - 跨平台模块（Linux 与 Apple 平台都必须能构建与测试）

var targets: [Target] = [
    .target(name: "AetherFoundation"),
    .target(name: "AetherProfile", dependencies: ["AetherFoundation"]),
    .target(name: "AetherRules", dependencies: ["AetherFoundation"]),
    .target(name: "AetherDNS", dependencies: ["AetherFoundation"]),
    .target(name: "AetherOutbound", dependencies: ["AetherFoundation"]),
    .target(name: "AetherCertificates", dependencies: ["AetherFoundation"]),
    .target(name: "AetherScriptCore", dependencies: ["AetherFoundation"]),
    .target(
        name: "AetherHTTP",
        dependencies: ["AetherOutbound", "AetherRules", "AetherCertificates", "AetherScriptCore"]
    ),
    .target(name: "AetherIPC", dependencies: ["AetherFoundation"]),
    .target(name: "AetherStore", dependencies: ["AetherFoundation"]),
    .target(
        name: "AetherEngine",
        dependencies: ["AetherProfile", "AetherRules", "AetherDNS", "AetherHTTP", "AetherIPC", "AetherStore"]
    ),
    .executableTarget(name: "aether-cli", dependencies: ["AetherEngine"]),

    .testTarget(name: "AetherFoundationTests", dependencies: ["AetherFoundation"]),
    .testTarget(name: "AetherProfileTests", dependencies: ["AetherProfile"]),
    .testTarget(name: "AetherRulesTests", dependencies: ["AetherRules"]),
    .testTarget(name: "AetherDNSTests", dependencies: ["AetherDNS"]),
    .testTarget(name: "AetherOutboundTests", dependencies: ["AetherOutbound"]),
    .testTarget(name: "AetherCertificatesTests", dependencies: ["AetherCertificates"]),
    .testTarget(name: "AetherScriptCoreTests", dependencies: ["AetherScriptCore"]),
    .testTarget(name: "AetherHTTPTests", dependencies: ["AetherHTTP"]),
    .testTarget(name: "AetherIPCTests", dependencies: ["AetherIPC"]),
    .testTarget(name: "AetherStoreTests", dependencies: ["AetherStore"]),
    .testTarget(name: "AetherEngineTests", dependencies: ["AetherEngine"]),
]

var products: [Product] = [
    .library(name: "AetherFoundation", targets: ["AetherFoundation"]),
    .library(name: "AetherProfile", targets: ["AetherProfile"]),
    .library(name: "AetherRules", targets: ["AetherRules"]),
    .library(name: "AetherDNS", targets: ["AetherDNS"]),
    .library(name: "AetherOutbound", targets: ["AetherOutbound"]),
    .library(name: "AetherCertificates", targets: ["AetherCertificates"]),
    .library(name: "AetherScriptCore", targets: ["AetherScriptCore"]),
    .library(name: "AetherHTTP", targets: ["AetherHTTP"]),
    .library(name: "AetherIPC", targets: ["AetherIPC"]),
    .library(name: "AetherStore", targets: ["AetherStore"]),
    .library(name: "AetherEngine", targets: ["AetherEngine"]),
    .executable(name: "aether-cli", targets: ["aether-cli"]),
]

// MARK: - Apple 专有模块（只在 Apple 主机上声明，保证 Linux 上 `swift build` 可用）

#if canImport(Darwin)
    targets += [
        .target(name: "AetherScript", dependencies: ["AetherScriptCore"]),
        .target(name: "AetherControl", dependencies: ["AetherIPC"]),
        .target(name: "AetherTunnelSupport", dependencies: ["AetherEngine"]),

        .testTarget(name: "AetherScriptTests", dependencies: ["AetherScript"]),
        .testTarget(name: "AetherControlTests", dependencies: ["AetherControl"]),
        .testTarget(name: "AetherTunnelSupportTests", dependencies: ["AetherTunnelSupport"]),
    ]
    products += [
        .library(name: "AetherScript", targets: ["AetherScript"]),
        .library(name: "AetherControl", targets: ["AetherControl"]),
        .library(name: "AetherTunnelSupport", targets: ["AetherTunnelSupport"]),
    ]
#endif

let package = Package(
    name: "AetherKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
