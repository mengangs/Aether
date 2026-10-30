# 03 工程与构建

## 1. 仓库结构

```text
Aether/
├── project.yml                      # XcodeGen 工程定义（.xcodeproj 由它生成，不入库）
├── Config/
│   ├── Base.xcconfig                # 所有 target 共用的构建设置
│   ├── Identifiers.xcconfig         # Bundle ID 前缀等标识符默认值
│   ├── Version.xcconfig             # MARKETING_VERSION
│   ├── Local.xcconfig.example       # 本地覆盖模板（DEVELOPMENT_TEAM、标识符）
│   ├── Local.xcconfig               # 本地覆盖（.gitignore，可选）
│   └── CI.xcconfig                  # CI 由仓库变量生成的标识符覆盖（.gitignore，见 §8.4）
├── App/
│   ├── Sources/                     # SwiftUI 界面、App 级服务
│   ├── Resources/                   # Assets.xcassets、Localizable.xcstrings、PrivacyInfo.xcprivacy
│   ├── Info.plist                   # 由 XcodeGen 按 project.yml 生成（.gitignore）
│   └── Aether.entitlements          # 同上
├── Tunnel/
│   ├── Sources/PacketTunnelProvider.swift 等
│   ├── Resources/PrivacyInfo.xcprivacy
│   ├── Info.plist                   # 由 XcodeGen 生成（.gitignore）
│   └── AetherTunnel.entitlements    # 同上
├── Widget/                          # M4
├── Share/                           # M7
├── Packages/
│   └── AetherKit/
│       ├── Package.swift
│       ├── Sources/<模块>/          # 模块清单见 02 §3
│       ├── Tests/<模块>Tests/
│       ├── Tests/Fixtures/          # 配置、规则集、DNS 报文、证书等测试数据
│       └── Binaries/                # 本地编译的 xcframework（.gitignore）
├── Vendor/
│   ├── hev-socks5-tunnel/           # git submodule，固定到发布 tag
│   └── blake3/                      # BLAKE3 官方 C 源码（拷贝，附 LICENSE 与来源版本）
├── Scripts/
│   ├── bootstrap.sh                 # 一键：编译 vendored 库 + 生成工程
│   ├── build-hev.sh                 # 编译 HevSocks5Tunnel.xcframework
│   ├── write-ci-xcconfig.sh         # 由环境变量生成 Config/CI.xcconfig
│   ├── check-architecture.swift     # 架构约束检查（§9）
│   └── interop/                     # 互通测试的 docker compose 与服务端配置
├── docs/
├── examples/
├── .github/workflows/
├── .swift-format
├── CHANGELOG.md
├── CLAUDE.md
└── README.md
```

`.gitignore` 至少包含：`*.xcodeproj/`、`*.xcworkspace/`、`.swiftpm/`、`DerivedData/`、`.build/`、`Packages/AetherKit/Binaries/`、`Config/Local.xcconfig`、`Config/CI.xcconfig`、`build/`，以及 XcodeGen 生成的各 target 的 `Info.plist` 与 `.entitlements`（它们完全由 `project.yml` 决定，入库只会制造与 `project.yml` 不一致的机会）。

## 2. 工具链

| 工具 | 版本 | 用途 |
| --- | --- | --- |
| Xcode | 27.x（Swift 6.4）；26.x 可作为备选 | iOS 工程构建 |
| Swift 工具链 | 6.x（Linux 上用 [swiftly](https://www.swift.org/install/) 安装） | `AetherKit` 跨平台构建与测试 |
| XcodeGen | 最新稳定版（`brew install xcodegen`） | 生成工程 |
| swift-format | 随 Swift 6 工具链提供（`swift format`） | 格式检查 |
| Docker | 任意近期版本 | 互通测试的服务端 |

- 部署目标：iOS 17.0。
- 语言模式：Swift 6，完整并发检查（`SWIFT_STRICT_CONCURRENCY = complete`；Package 中 `swiftLanguageModes: [.v6]`）。
- `Package.swift` 的 `swift-tools-version` 为 6.0，以兼容较旧的 6.x 工具链。

## 3. 标识符与签名配置

### 3.1 xcconfig

`Config/Identifiers.xcconfig`：

```xcconfig
// 通用默认值；可在 Local.xcconfig（本地）或 CI.xcconfig（CI，来自仓库变量）中覆盖。
AETHER_BUNDLE_ID_PREFIX = com.example.aether                      // 主 App 的 Bundle ID，兼作前缀
AETHER_TUNNEL_BUNDLE_ID = $(AETHER_BUNDLE_ID_PREFIX).tunnel       // 可单独覆盖
AETHER_WIDGET_BUNDLE_ID = $(AETHER_BUNDLE_ID_PREFIX).widget       // 可单独覆盖（M4）
AETHER_TEAM_ID = $(DEVELOPMENT_TEAM)
AETHER_APP_GROUP = group.$(AETHER_BUNDLE_ID_PREFIX)
AETHER_KEYCHAIN_GROUP = $(AETHER_TEAM_ID).$(AETHER_BUNDLE_ID_PREFIX).shared
AETHER_URL_SCHEME = aether
```

- 仓库中只保留通用默认值，不得写入个人或团队的真实标识符。
- `AETHER_BUNDLE_ID_PREFIX` 是主 App 的 Bundle ID，同时用作日志 subsystem、Darwin 通知名、后台任务与导出 UTI 的前缀。
- 扩展的 Bundle ID 用 `AETHER_TUNNEL_BUNDLE_ID` / `AETHER_WIDGET_BUNDLE_ID` 单独覆盖，不强制等于"前缀.tunnel"；但 iOS 安装时要求扩展的 Bundle ID 以主 App 的 Bundle ID 加 `.` 开头，覆盖时须遵守。
- Keychain 访问组不用 `$(AppIdentifierPrefix)`：未签名构建时它为空，组名会缺少 Team ID 前缀。改用 `AETHER_TEAM_ID` 显式拼出；运行时再按 §3.2 探测一次实际前缀。
- 覆盖优先级（低 → 高）：`Identifiers.xcconfig` → `Local.xcconfig` → `CI.xcconfig`。

`Config/Base.xcconfig`：

```xcconfig
#include "Identifiers.xcconfig"
#include "Version.xcconfig"
#include? "Local.xcconfig"
#include? "CI.xcconfig"

IPHONEOS_DEPLOYMENT_TARGET = 17.0
TARGETED_DEVICE_FAMILY = 1,2
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
CODE_SIGN_STYLE = Automatic
ENABLE_USER_SCRIPT_SANDBOXING = YES
DEAD_CODE_STRIPPING = YES
```

`Config/Version.xcconfig`：

```xcconfig
MARKETING_VERSION = 0.1.0
CURRENT_PROJECT_VERSION = 1   // CI 以提交计数覆盖，见 §8
```

`Config/Local.xcconfig.example`：

```xcconfig
// 复制为 Local.xcconfig 后填写；该文件不入库。
DEVELOPMENT_TEAM = XXXXXXXXXX
AETHER_BUNDLE_ID_PREFIX = com.yourname.aether
// 可选：AETHER_TUNNEL_BUNDLE_ID、AETHER_WIDGET_BUNDLE_ID、AETHER_APP_GROUP、AETHER_TEAM_ID、AETHER_KEYCHAIN_GROUP
```

### 3.2 运行时读取标识符

各 target 的 Info.plist 写入：

| 键 | 值 |
| --- | --- |
| `AetherBundleIdentifierPrefix` | `$(AETHER_BUNDLE_ID_PREFIX)` |
| `AetherAppGroupIdentifier` | `$(AETHER_APP_GROUP)` |
| `AetherKeychainAccessGroup` | `$(AETHER_KEYCHAIN_GROUP)` |
| `AetherTunnelBundleIdentifier` | `$(AETHER_TUNNEL_BUNDLE_ID)` |
| `AetherURLScheme` | `$(AETHER_URL_SCHEME)` |

代码只通过 `AetherIPC` 中的 `AppEnvironment` 读取：

```swift
public struct AppEnvironment: Sendable, Equatable {
    public let bundleIdentifierPrefix: String
    public let appGroupIdentifier: String
    public let keychainAccessGroup: String
    public let tunnelBundleIdentifier: String
    public let urlScheme: String
    public init(infoDictionary: [String: Any]) throws          // 缺键、值为空、含未展开的 $(...) 时抛 IPC-020
    public static func fromMainBundle() throws -> AppEnvironment  // 不得回退到硬编码值
    public func resolvingKeychainAccessGroup(probed: String?) -> (AppEnvironment, KeychainAccessGroupResolution)
}
```

- App 与隧道启动时调用 `AetherKeychain` 中的 `AppEnvironment.loadForCurrentProcess(logger:)`：读取 Info.plist，再用 `KeychainAccessGroupProbe` 探测实际的访问组前缀并校正（§8.4），校正或探测失败时写日志。
- App Group 中的目录布局由 `AetherIPC` 的 `SharedContainer` 给出（[11 §3](11-storage.md#3-文件布局)）；容器不可用时抛 `STO-001`。

- `NETunnelProviderProtocol.providerBundleIdentifier` 取 `tunnelBundleIdentifier`。
- App Group 容器用 `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`，返回 `nil` 时在界面上显示"App Group 不可用"的明确错误，而不是崩溃。
- Keychain 读写一律显式传 `kSecAttrAccessGroup`。

### 3.3 Entitlements

| 键 | App | Tunnel | Widget |
| --- | --- | --- | --- |
| `com.apple.developer.networking.networkextension` = `[packet-tunnel-provider]` | ✓ | ✓ | 🔬（控制中心开关若需在扩展进程内启停隧道） |
| `com.apple.security.application-groups` = `[$(AETHER_APP_GROUP)]` | ✓ | ✓ | ✓ |
| `keychain-access-groups` = `[$(AETHER_KEYCHAIN_GROUP)]` | ✓ | ✓ | — |
| `com.apple.developer.networking.wifi-info` = `true` | ✓ | ✓ | — |

entitlements 只声明表中这些实际需要的值：`networkextension` 只写 `packet-tunnel-provider`，不声明 app-proxy、content-filter 等其它类型。

能力缺失时必须优雅降级，不得崩溃：缺 `wifi-info` 时 SSID 不可用（相关规则与按需连接条件按"未知网络"处理并给出诊断）；App Group 不可用时 App 显示明确的错误页（`STO-001`）；Keychain 访问组不可用时 MitM 等依赖 Keychain 的功能报错并保持关闭。

`wifi-info` 用于 SSID 条件（SUBNET 规则、按需连接）。读取当前 Wi-Fi 信息需同时满足"App 已安装有效的 VPN 配置"等系统条件，详见 [06 §11](06-network-engine.md#11-网络环境与切换)。

### 3.4 Info.plist 要点（App）

- `UILaunchScreen`（字典，可为空）与场景生命周期：Xcode 27 / iOS 27 SDK 构建时必需。SwiftUI `App` 生命周期自动满足场景要求。
- `CFBundleURLTypes`：scheme 为 `$(AETHER_URL_SCHEME)`。
- `CFBundleDocumentTypes` 与 `UTExportedTypeDeclarations`：导出 `.amodule`（`$(AETHER_BUNDLE_ID_PREFIX).module`）；导入 `.conf`、`.sgmodule`、`.yaml` / `.yml`、`.js`。`LSSupportsOpeningDocumentsInPlace = NO`（导入时复制）。
- `NSCameraUsageDescription`：扫描二维码导入（M4）。
- `NSLocalNetworkUsageDescription`：局域网共享与 HTTP 控制接口（M7）。
- `UIBackgroundModes = [fetch]` 与 `BGTaskSchedulerPermittedIdentifiers = [$(AETHER_BUNDLE_ID_PREFIX).refresh]`：后台更新外部资源（M3）。

### 3.5 隐私清单

每个 target 带 `PrivacyInfo.xcprivacy`：`NSPrivacyTracking = false`，`NSPrivacyCollectedDataTypes = []`，`NSPrivacyAccessedAPITypes` 按实际使用声明（预计：UserDefaults `1C8F.1`（App Group 共享）、FileTimestamp `C617.1`、SystemBootTime `35F9.1`、DiskSpace `E174.1`）。新增相关 API 调用时同步更新。

## 4. XcodeGen

工程定义以仓库根目录的 `project.yml` 为准（随里程碑增补 target）。要点：

- 项目级 `configFiles` 指向 `Config/Base.xcconfig`（Debug 与 Release 相同），开发语言 `zh-Hans`。
- `AetherKit` 以本地包引用（`packages.AetherKit.path: Packages/AetherKit`）。
- `Aether`（application）：源码 `App/Sources`、`App/Resources`；`PRODUCT_BUNDLE_IDENTIFIER = $(AETHER_BUNDLE_ID_PREFIX)`；依赖 `AetherTunnel` target 与 `AetherKit` 的 `AetherProfile`、`AetherRules`、`AetherIPC`、`AetherStore`、`AetherControl`（M5 起加 `AetherCertificates`，M6 起加 `AetherScript`，见 02 §3.2）。
- `AetherTunnel`（app-extension，`com.apple.networkextension.packet-tunnel`，主类 `$(PRODUCT_MODULE_NAME).PacketTunnelProvider`）：`PRODUCT_BUNDLE_IDENTIFIER = $(AETHER_TUNNEL_BUNDLE_ID)`；依赖 `AetherEngine`、`AetherTunnelSupport`、`AetherScript`、`AetherIPC`、`AetherStore`。
- 两个 target 的 Info.plist 与 entitlements 由 `info.properties` / `entitlements.properties` 生成，内容见 §3.2–§3.4；其中的标识符全部是 `$(AETHER_*)` 变量。
- 每个 target 的 `info.properties` 都必须写 `CFBundleShortVersionString: $(MARKETING_VERSION)` 与 `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`：XcodeGen 生成 Info.plist 时默认填入字面量 `1.0` / `1`，不会引用构建设置。
- scheme `Aether` 构建 App 与 Tunnel；Run 用 Debug，Archive 用 Release。
- `Scripts/check-architecture.swift` 解析 `project.yml` 中 App 与小组件的 `products`，拒绝直接或间接依赖引擎相关模块。

修改工程结构只改 `project.yml`，然后重新运行 `./Scripts/bootstrap.sh`。XcodeGen 语法以其官方文档为准；上面的骨架如与当前版本语法不符，以能生成可构建工程为准修正并更新本节。

## 5. 依赖

### 5.1 Swift 包

全部使用最新稳定主版本，`Packages/AetherKit/Package.resolved` 入库锁定。Xcode 不读取本地包自己的 `Package.resolved`，`bootstrap.sh` 在生成工程后把它拷贝到 `Aether.xcodeproj` 的 workspace 中，保证 App 与 `swift test` 使用同一组版本。首次引入时把实际版本填入下表。

| 包 | 许可证 | 使用模块 | 用途 | 版本 |
| --- | --- | --- | --- | --- |
| apple/swift-nio | Apache-2.0 | Engine、Outbound、DNS、HTTP；AetherTestSupport（回环测试服务） | 事件循环、Channel、HTTP/1、WebSocket | 2.104.0 |
| apple/swift-nio-ssl | Apache-2.0（内含 BoringSSL：ISC 与 OpenSSL 许可证组合，均为宽松许可证） | Outbound、HTTP；AetherTestSupport | TLS 客户端与服务端 | 2.37.5 |
| apple/swift-nio-http2 | Apache-2.0 | HTTP | HTTP/2 MitM（M7）、DoH over h2 | |
| apple/swift-nio-extras | Apache-2.0 | HTTP | HTTP 压缩等辅助 Handler | |
| apple/swift-crypto | Apache-2.0 | Profile、Outbound、Certificates | AEAD、哈希（含配置修订号）、HKDF、密钥；`_CryptoExtras`（RSA 等） | 5.0.3 |
| apple/swift-certificates | Apache-2.0 | Certificates、Outbound；AetherTestSupport（测试时临时生成 CA 与服务器证书，仓库中不存私钥） | X.509 生成与签发（MitM）；TLS 服务器身份（主机名）校验 | 1.21.1（swift-nio-ssl 也依赖它） |
| apple/swift-asn1 | Apache-2.0 | Certificates | swift-crypto、swift-certificates 的依赖 | 1.7.3（由 swift-crypto 引入） |
| apple/swift-log | Apache-2.0 | 全部 | 日志门面 | 1.16.2 |
| apple/swift-collections | Apache-2.0 | 全部 | `Deque`、`OrderedDictionary` | 1.7.5（由 swift-nio 引入） |
| apple/swift-atomics | Apache-2.0 | Engine | 原子引用、计数器 | 1.3.1（由 swift-nio 引入） |
| apple/swift-system | Apache-2.0 | —（swift-nio 的依赖） | 系统调用封装 | 1.8.1（由 swift-nio 引入） |
| jpsim/Yams | MIT | Profile | 解析 YAML 格式的节点订阅 | |
| groue/GRDB.swift | MIT | Store | SQLite 访问 | 7.11.1 |
| simonbs/Runestone | MIT | App（M4） | 配置文本编辑器（语法高亮、行号） | |

### 5.2 C 库

| 库 | 许可证 | 形式 | 用途 |
| --- | --- | --- | --- |
| heiher/hev-socks5-tunnel 2.19.3（含其子模块 lwIP、hev-task-system、yaml、hev-socks5-core） | MIT（lwIP 为 BSD） | git submodule → xcframework | TUN ↔ SOCKS5 |
| BLAKE3 官方 C 实现（1.8.7） | CC0-1.0 / Apache-2.0 | 源码拷贝 | Shadowsocks 2022 密钥派生 |
| SQLite | 公有领域 | 系统库：Apple 平台用 SDK 自带的 `libsqlite3`；Linux 需安装 `libsqlite3-dev`（GRDB 的 `GRDBSQLite` 系统库目标） | GRDB 的存储引擎 |

### 5.3 引入新依赖的检查

1. 许可证在 ADR-009 允许范围内，且其传递依赖同样满足。
2. 支持 iOS 17，"全部平台"模块的依赖还必须支持 Linux。
3. 评估对隧道内存与二进制体积的影响，写入提交说明。
4. 更新本表与 App 内"开源许可"页面（M4 起由构建脚本从各依赖的 LICENSE 文件汇总生成）。

### 5.4 Package.swift 平台条件

Apple 专有模块与二进制 target 只在 Apple 主机上声明，保证 Linux 上 `swift build` 可用：

```swift
// swift-tools-version: 6.0
import PackageDescription

var targets: [Target] = [
    .target(name: "AetherFoundation", dependencies: [/* swift-log, swift-collections */]),
    // ... 其余跨平台模块
    .executableTarget(name: "aether-cli", dependencies: ["AetherEngine"]),
]
var products: [Product] = [/* 跨平台模块的 library 产品 */]

#if canImport(Darwin)
targets += [
    .binaryTarget(name: "CHevSocks5Tunnel", path: "Binaries/HevSocks5Tunnel.xcframework"),
    .target(name: "AetherTunnelSupport", dependencies: ["AetherEngine", "CHevSocks5Tunnel"]),
    .target(name: "AetherScript", dependencies: ["AetherScriptCore"]),
    .target(name: "AetherControl", dependencies: ["AetherIPC"]),
    .testTarget(name: "AetherScriptTests", dependencies: ["AetherScript"]),
]
products += [
    .library(name: "AetherTunnelSupport", targets: ["AetherTunnelSupport"]),
    .library(name: "AetherScript", targets: ["AetherScript"]),
    .library(name: "AetherControl", targets: ["AetherControl"]),
]
#endif

let package = Package(
    name: "AetherKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: products,
    dependencies: [/* ... */],
    targets: targets,
    swiftLanguageModes: [.v6]
)
```

`macOS(.v14)` 只用于在 macOS 主机上运行 `swift test`，不发布 macOS 产品。

## 6. Vendored C 库

### 6.1 hev-socks5-tunnel

- 以 git submodule 放在 `Vendor/hev-socks5-tunnel`，固定到一个发布 tag（当前 `2.19.3`）；升级时在提交说明中写明变更摘要。
- `Scripts/build-hev.sh`（仅 macOS）：
  1. `git submodule update --init --recursive`；
  2. 在临时副本中用上游 Makefile 的 `static` 目标逐个切片编译，再按上游 `build-apple.sh` 的方式用 `libtool` / `lipo` 合并：iOS 设备 arm64、iOS 模拟器 arm64 + x86_64、macOS arm64 + x86_64（macOS 切片供 macOS 主机上的 `swift test` 链接 `AetherTunnelSupport`）。最低版本 iOS 17.0 / macOS 14.0；追加 `-Wno-error`，避免新编译器对 vendored 代码的警告阻断构建；
  3. 写入暴露 `hev-main.h` 的模块映射，模块名 `CHevSocks5Tunnel`（头文件位于 `Headers/CHevSocks5Tunnel/`）；
  4. 输出到 `Packages/AetherKit/Binaries/HevSocks5Tunnel.xcframework`；
  5. 在产物旁写 `VERSION`（submodule commit + 脚本哈希），两者一致时跳过重复构建。
- 不直接调用上游的 `build-apple.sh`：它还会构建 tvOS 切片（不需要，且 runner 不一定安装 tvOS 平台），模块名也是 `HevSocks5Tunnel`。
- CI 以 submodule commit、脚本哈希与 Xcode 版本作为缓存键缓存该 xcframework。
- macOS 上首次 `swift build` / `swift test` 之前必须先运行 `build-hev.sh`（或 `bootstrap.sh`），否则 `CHevSocks5Tunnel` 二进制 target 不存在；Linux 上不声明该 target，不受影响。

### 6.2 BLAKE3

拷贝官方仓库 `c/` 目录中的可移植实现（`blake3.c`、`blake3_dispatch.c`、`blake3_portable.c` 与头文件，当前版本 1.8.7）到 `Vendor/blake3`，并在 `Packages/AetherKit/Sources/CBlake3` 中以符号链接引用（SwiftPM 跟随相对符号链接，Linux 与 macOS 均可）。编译宏关闭所有 SIMD 分支（`BLAKE3_NO_SSE2`、`BLAKE3_NO_SSE41`、`BLAKE3_NO_AVX2`、`BLAKE3_NO_AVX512`、`BLAKE3_USE_NEON=0`），保证 Linux x86_64 与 iOS arm64 行为一致；它只用于每会话一次的密钥派生，性能足够。保留上游 LICENSE 与版本号文件。

### 6.3 bootstrap.sh

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
./Scripts/build-hev.sh
xcodegen generate --spec project.yml
echo "Aether.xcodeproj generated."
```

## 7. CI（GitHub Actions）

| 工作流 | 运行环境 | 触发 | 内容 |
| --- | --- | --- | --- |
| `core.yml` | `ubuntu-latest` + Swift 6.x 官方容器 | push 到 main | `swift format lint --recursive`；`swift build`；`swift test --parallel`（跨平台模块） |
| `interop.yml` | `ubuntu-latest` + Docker | 每日定时、手动；push 到 main 且改动涉及 `AetherOutbound` 或 `Scripts/interop/` | 启动 `Scripts/interop/` 中的测试服务端；运行 `swift test --filter Interop` |
| `ios.yml` | `xcode-27`（备选 `macos-26`） | push 到 main | 恢复或构建 hev 缓存；`bootstrap.sh`；在 macOS 上 `swift test`（含 Apple 专有模块）；`xcodebuild build -scheme Aether -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO` |
| `release.yml` | `xcode-27` | 推送 `v*` tag、手动（`workflow_dispatch`） | 未签名 ipa 与附带文件，见 §8.3–§8.4 |

`ios.yml` 的核心步骤：

```yaml
jobs:
  build:
    runs-on: xcode-27
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
          fetch-depth: 0
      - id: hev
        run: echo "rev=$(git -C Vendor/hev-socks5-tunnel rev-parse HEAD)" >> "$GITHUB_OUTPUT"
      - name: Cache hev xcframework
        uses: actions/cache@v4
        with:
          path: Packages/AetherKit/Binaries
          key: hev-${{ steps.hev.outputs.rev }}-${{ hashFiles('Scripts/build-hev.sh') }}
      - run: brew install xcodegen
      - run: ./Scripts/bootstrap.sh
      - name: Package tests (macOS host)
        run: swift test --package-path Packages/AetherKit
      - name: Build iOS
        run: |
          xcodebuild build \
            -project Aether.xcodeproj -scheme Aether \
            -destination 'generic/platform=iOS' \
            -configuration Debug \
            CODE_SIGNING_ALLOWED=NO \
            CURRENT_PROJECT_VERSION=$(git rev-list --count HEAD)
```

Actions 的版本号与 runner 标签以当时 GitHub 官方文档为准；runner 镜像变更导致构建失败时，优先固定 Xcode 版本（`sudo xcode-select -s /Applications/Xcode_<版本>.app`），并在本节记录。

当前固定的版本（2026-10，M0-05 起）：

| 项 | 值 | 说明 |
| --- | --- | --- |
| macOS runner | `xcode-27`（arm64，macOS 27） | GitHub 的 Xcode 27 专用镜像（public preview）；不可用时退回 `macos-26`（默认 Xcode 26.6） |
| Xcode | `/Applications/Xcode_27.1.app`（镜像默认版本） | 在 `ios.yml` / `release.yml` 的 `XCODE_APP` 中固定 |
| Linux 容器 | `swift:6.4-noble`（Docker Hub 官方镜像）+ `libsqlite3-dev` | 作业中先 `apt-get install libsqlite3-dev`（M2-12 起，GRDB 需要）；本地复现：`docker run --rm -v "$PWD":/src -w /src/Packages/AetherKit swift:6.4-noble bash -c "apt-get update && apt-get install -y libsqlite3-dev && swift test"` |
| Actions | `actions/checkout@v7`、`actions/cache@v6`、`actions/upload-artifact@v7` | |

`ios.yml` 的步骤随 M0 任务逐步补全：M0-05 只在 macOS 主机上运行架构检查与 `swift test`；M0-03 加入 hev 缓存与 `build-hev.sh`；M0-04 加入 XcodeGen 与 `xcodebuild build`。

macOS 主机上的包测试（M2-06 起）：先单独构建（`swift build --build-tests`），再串行运行（`swift test --skip-build --no-parallel`），由 `Scripts/ci-run.sh` 的看门狗（`CI_RUN_TIMEOUT`，当前 300 秒）限时；超时后打印 `swift test` 与测试进程的全部线程调用栈（lldb，失败时用 `sample`），再结束整个进程树。测试进程的输出经管道转发时有缓冲，日志中最后一条 `started` 不一定是卡住的测试，以调用栈与事件循环线程编号为准。

项目直接在 `main` 上开发，不使用 PR。每次推送 `main` 后 `core.yml` 与 `ios.yml` 必须全部通过；任一失败时优先修复，修到通过后再开始下一个任务。

## 8. 版本号与发布

### 8.1 版本号

- `MARKETING_VERSION`：语义化版本，写在 `Config/Version.xcconfig`。里程碑与版本对应见 [01 §5](01-product.md#5-版本划分)。
- `CURRENT_PROJECT_VERSION`：CI 中取 `git rev-list --count HEAD`，保证单调递增。
- tag 格式 `v0.3.0`；每个 tag 对应 `CHANGELOG.md`（Keep a Changelog 格式）中的一节。

### 8.2 分支与提交

- 直接提交并推送到 `main`，不建功能分支、不开 PR。`main` 始终可构建。
- 提交信息遵循 Conventional Commits，并在描述开头带 roadmap 任务编号：`feat(engine): [M2-06] SOCKS5 outbound`、`fix(dns): [M2-02] ...`、`docs: [M1-03] ...`、`test(rules): [M1-07] ...`、`chore(ci): [M0-05] ...`。scope 使用模块或 target 名的小写短名（profile、rules、dns、outbound、http、engine、ipc、store、script、tunnel、app、widget、ci、docs）。不属于任何任务的提交（如修复 CI 环境）可省略编号。
- 修改文档的原因、依赖评估等原本写在 PR 描述中的内容，写在提交说明正文里。
- 每次推送后 CI 必须通过；失败时优先修复，修到通过后再推进下一个任务。

### 8.3 发布构建

`release.yml` 有两种触发方式：推送 `v*` tag，或在 Actions 页面手动运行（`workflow_dispatch`，可选 Release / Debug 配置）。步骤：

1. 与 `ios.yml` 相同的准备步骤（hev 缓存、XcodeGen、标识符覆盖 §8.4）；tag 触发时检查 tag 与 `MARKETING_VERSION` 一致；
2. `xcodebuild archive` 以 `CODE_SIGNING_ALLOWED=NO` 生成未签名的 `Aether.xcarchive`，`CURRENT_PROJECT_VERSION` 取提交计数；
3. `Scripts/package-release.sh` 打包产物：
   - `Aether-<版本>-<构建号>-unsigned.ipa`：标准结构 `Payload/Aether.app`（含 `PlugIns/AetherTunnel.appex`），未签名；
   - `entitlements/Aether.entitlements`、`entitlements/AetherTunnel.entitlements`：各 target 的 entitlements，`$(AETHER_*)` 已按本次构建的设置展开；
   - `identifiers.json` / `identifiers.txt`：标识符清单（版本、提交、Team ID、各 Bundle ID、App Group、Keychain 访问组、URL Scheme）；
   - `Aether-<版本>-<构建号>-dSYMs.zip`；
   - 打包后自检 ipa 结构，并检查扩展 Bundle ID 与 App 中记录的一致；
4. 产物上传为 workflow artifact；tag 触发时另外创建 GitHub Release（`0.x` 标为 pre-release），说明取 `CHANGELOG.md` 对应节。若该 tag 的 Release 已存在（例如在网页上先创建），则更新说明并覆盖附件。

项目不在 CI 中保存签名机密，发布产物一律是未签名 ipa，由使用者按 §8.4 自行签名。

### 8.4 自行签名

未签名 ipa 要能在重签后直接使用，工程与代码遵守以下要求：

1. **标识符可由仓库变量覆盖**。仓库中只保留通用默认值（§3.1）。在 GitHub 仓库 Settings → Secrets and variables → Actions → **Variables** 中设置以下变量，`ios.yml` 与 `release.yml` 通过 `Scripts/write-ci-xcconfig.sh` 生成 `Config/CI.xcconfig` 覆盖默认值；未设置的变量沿用默认值：

   | 变量 | 含义 | 默认值 |
   | --- | --- | --- |
   | `AETHER_BUNDLE_ID_PREFIX` | 主 App 的 Bundle ID（兼作日志、通知名等的前缀） | `com.example.aether` |
   | `AETHER_TUNNEL_BUNDLE_ID` | 隧道扩展的 Bundle ID | `<前缀>.tunnel` |
   | `AETHER_WIDGET_BUNDLE_ID` | 小组件扩展的 Bundle ID（M4 起使用） | `<前缀>.widget` |
   | `AETHER_APP_GROUP` | App Group | `group.<前缀>` |
   | `AETHER_KEYCHAIN_GROUP` | Keychain 访问组（完整值，含 Team ID 前缀） | `<Team ID>.<前缀>.shared` |
   | `AETHER_TEAM_ID` | Team ID | 空 |
   | `AETHER_URL_SCHEME` | URL Scheme | `aether` |

   变量值只允许字母、数字、`.` 与 `-`。扩展的 Bundle ID 必须以主 App 的 Bundle ID 加 `.` 开头（iOS 安装要求）。
2. **Keychain 访问组显式拼出**。未签名构建时 `$(AppIdentifierPrefix)` 为空，所以访问组用 `AETHER_TEAM_ID` 拼出。运行时再探测一次实际前缀：写入一个不指定访问组的临时 Keychain 项，读回系统赋予的 `kSecAttrAccessGroup`，取其第一个 `.` 之前的部分作为实际 Team ID 前缀；与 Info.plist 中的访问组前缀不一致时以探测结果为准（保留其余部分），并写日志（见 §3.2）。
3. **能力缺失时优雅降级**（§3.3）：缺 `wifi-info` 时 SSID 不可用；App Group 不可用时显示明确的错误页（`STO-001`）；均不得崩溃。
4. **entitlements 只声明实际需要的值**（§3.3），`networkextension` 只写 `packet-tunnel-provider`。描述文件需要包含对应能力：Network Extensions（Packet Tunnel）、App Groups、Keychain Sharing、Access Wi-Fi Information。
5. **发布产物附带签名所需信息**（§8.3）：App 与 Tunnel 的 entitlements 文件、标识符清单。重签时先用 `AetherTunnel.entitlements` 签 `Payload/Aether.app/PlugIns/AetherTunnel.appex`，再用 `Aether.entitlements` 签 `Payload/Aether.app`；两者的 Bundle ID、App Group、Keychain 访问组应与 `identifiers.txt` 一致。

## 9. 代码规范

- 格式：仓库根目录 `.swift-format`（4 空格缩进，行宽 120）。CI 以 `swift format lint --strict` 检查，lint 失败即失败；提交前可用 `swift format format -i --recursive Sources Tests` 自动修正。
- 架构约束：`Scripts/check-architecture.swift` 检查模块依赖方向（02 §3.2）、跨平台模块禁止的 import，以及 `project.yml` 中 App / 小组件不得依赖引擎相关模块；CI 在 Linux 与 macOS 上都运行它。新增模块时同时更新该脚本中的依赖图与 02 §3。
- 命名：类型 `UpperCamelCase`，协议描述能力（`OutboundConnector`、`ScriptRuntime`）；配置关键字与诊断码保持原文大小写。
- 访问控制：模块对外只暴露必要类型，默认 `internal`；跨模块 API 写文档注释。
- 禁止：`print`、`fatalError` / `try!` / 强制解包出现在数据面代码中（测试代码除外）；在 EventLoop 上阻塞；无上限的缓冲或集合；硬编码标识符；Apple 私有 API。
- 每个公开类型或重要算法附单元测试；协议实现附官方测试向量或互通测试（见 [13](13-testing.md)）。
