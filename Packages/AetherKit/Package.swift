// swift-tools-version: 6.0
// AetherKit：Aether 的全部业务逻辑。模块清单与依赖方向见 docs/02-architecture.md §3，
// 平台条件见 docs/03-project-setup.md §5.4。
import PackageDescription

// MARK: - 跨平台模块（Linux 与 Apple 平台都必须能构建与测试）

var targets: [Target] = [
    // BLAKE3 官方 C 实现（Vendor/blake3 的符号链接），关闭全部 SIMD 分支（docs/03 §6.2）。
    .target(
        name: "CBlake3",
        cSettings: [
            .define("BLAKE3_NO_SSE2"),
            .define("BLAKE3_NO_SSE41"),
            .define("BLAKE3_NO_AVX2"),
            .define("BLAKE3_NO_AVX512"),
            .define("BLAKE3_USE_NEON", to: "0"),
        ]
    ),
    .target(name: "AetherFoundation", dependencies: [.product(name: "Logging", package: "swift-log")]),
    .target(
        name: "AetherProfile",
        dependencies: ["AetherFoundation", .product(name: "Crypto", package: "swift-crypto")]
    ),
    .target(name: "AetherRules", dependencies: ["AetherFoundation"]),
    .target(name: "AetherDNS", dependencies: ["AetherFoundation"]),
    .target(name: "AetherOutbound", dependencies: ["AetherFoundation", "CBlake3"]),
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
    // 基准（docs/13 §5.1）：swift run -c release aether-bench
    .executableTarget(name: "aether-bench", dependencies: ["AetherEngine"]),

    // 测试数据与测试工具，只供测试 target 依赖。
    .target(name: "AetherTestSupport"),
    .testTarget(name: "CBlake3Tests", dependencies: ["CBlake3", "AetherTestSupport"]),

    .testTarget(name: "AetherFoundationTests", dependencies: ["AetherFoundation", "AetherTestSupport"]),
    .testTarget(name: "AetherProfileTests", dependencies: ["AetherProfile", "AetherTestSupport"]),
    .testTarget(name: "AetherRulesTests", dependencies: ["AetherRules", "AetherProfile", "AetherTestSupport"]),
    .testTarget(name: "AetherDNSTests", dependencies: ["AetherDNS"]),
    .testTarget(name: "AetherOutboundTests", dependencies: ["AetherOutbound"]),
    .testTarget(name: "AetherCertificatesTests", dependencies: ["AetherCertificates"]),
    .testTarget(name: "AetherScriptCoreTests", dependencies: ["AetherScriptCore"]),
    .testTarget(name: "AetherHTTPTests", dependencies: ["AetherHTTP"]),
    .testTarget(name: "AetherIPCTests", dependencies: ["AetherIPC", "AetherTestSupport"]),
    .testTarget(name: "AetherStoreTests", dependencies: ["AetherStore"]),
    .testTarget(name: "AetherEngineTests", dependencies: ["AetherEngine", "AetherTestSupport"]),
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
        // hev-socks5-tunnel 的 xcframework，由 Scripts/build-hev.sh 生成（docs/03 §6.1）。
        .binaryTarget(name: "CHevSocks5Tunnel", path: "Binaries/HevSocks5Tunnel.xcframework"),
        .target(name: "AetherScript", dependencies: ["AetherScriptCore"]),
        .target(name: "AetherControl", dependencies: ["AetherFoundation", "AetherIPC"]),
        .target(
            name: "AetherKeychain",
            dependencies: ["AetherFoundation", "AetherIPC", .product(name: "Logging", package: "swift-log")]
        ),
        .target(
            name: "AetherTunnelSupport",
            dependencies: ["AetherEngine", "AetherKeychain", "CHevSocks5Tunnel"]
        ),

        .testTarget(name: "AetherScriptTests", dependencies: ["AetherScript"]),
        .testTarget(name: "AetherControlTests", dependencies: ["AetherControl"]),
        .testTarget(name: "AetherKeychainTests", dependencies: ["AetherKeychain"]),
        .testTarget(name: "AetherTunnelSupportTests", dependencies: ["AetherTunnelSupport"]),
    ]
    products += [
        .library(name: "AetherScript", targets: ["AetherScript"]),
        .library(name: "AetherControl", targets: ["AetherControl"]),
        .library(name: "AetherKeychain", targets: ["AetherKeychain"]),
        .library(name: "AetherTunnelSupport", targets: ["AetherTunnelSupport"]),
    ]
#endif

// 外部依赖：许可证与用途见 docs/03 §5.1，引入前按 §5.3 检查。
let dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-log.git", from: "1.16.2"),
    .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3"),
]

let package = Package(
    name: "AetherKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v6]
)
