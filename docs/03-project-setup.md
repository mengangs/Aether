# 03 工程与构建

## 1. 仓库结构

```text
Aether/
├── project.yml                      # XcodeGen 工程定义（.xcodeproj 由它生成，不入库）
├── Config/
│   ├── Base.xcconfig                # 所有 target 共用的构建设置
│   ├── Identifiers.xcconfig         # Bundle ID 前缀等标识符默认值
│   ├── Version.xcconfig             # MARKETING_VERSION
│   ├── Local.xcconfig.example       # 本地覆盖模板（DEVELOPMENT_TEAM、标识符前缀）
│   └── Local.xcconfig               # 本地覆盖（.gitignore，可选）
├── App/
│   ├── Sources/                     # SwiftUI 界面、App 级服务
│   ├── Resources/                   # Assets.xcassets、Localizable.xcstrings、PrivacyInfo.xcprivacy
│   ├── Info.plist
│   └── Aether.entitlements
├── Tunnel/
│   ├── Sources/PacketTunnelProvider.swift 等
│   ├── Resources/PrivacyInfo.xcprivacy
│   ├── Info.plist
│   └── AetherTunnel.entitlements
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
│   └── interop/                     # 互通测试的 docker compose 与服务端配置
├── docs/
├── examples/
├── .github/workflows/
├── .swift-format
├── CHANGELOG.md
├── CLAUDE.md
└── README.md
```

`.gitignore` 至少包含：`*.xcodeproj/`、`*.xcworkspace/`（除 Package 内自动生成的以外）、`DerivedData/`、`.build/`、`Packages/AetherKit/Binaries/`、`Config/Local.xcconfig`、`build/`。

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
// 所有标识符由此派生。可在 Local.xcconfig 中覆盖。
AETHER_BUNDLE_ID_PREFIX = com.example.aether
AETHER_APP_GROUP = group.$(AETHER_BUNDLE_ID_PREFIX)
AETHER_KEYCHAIN_GROUP = $(AppIdentifierPrefix)$(AETHER_BUNDLE_ID_PREFIX).shared
AETHER_URL_SCHEME = aether
```

`Config/Base.xcconfig`：

```xcconfig
#include "Identifiers.xcconfig"
#include "Version.xcconfig"
#include? "Local.xcconfig"

IPHONEOS_DEPLOYMENT_TARGET = 17.0
TARGETED_DEVICE_FAMILY = 1,2
SWIFT_VERSION = 6.0
SWIFT_STRICT_CONCURRENCY = complete
CODE_SIGN_STYLE = Automatic
DEVELOPMENT_TEAM =
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
```

### 3.2 运行时读取标识符

各 target 的 Info.plist 写入：

| 键 | 值 |
| --- | --- |
| `AetherAppGroupIdentifier` | `$(AETHER_APP_GROUP)` |
| `AetherKeychainAccessGroup` | `$(AETHER_KEYCHAIN_GROUP)` |
| `AetherTunnelBundleIdentifier` | `$(AETHER_BUNDLE_ID_PREFIX).tunnel` |
| `AetherURLScheme` | `$(AETHER_URL_SCHEME)` |

代码只通过 `AetherIPC` 中的 `AppEnvironment` 读取：

```swift
public struct AppEnvironment: Sendable {
    public let appGroupIdentifier: String
    public let keychainAccessGroup: String
    public let tunnelBundleIdentifier: String
    public let urlScheme: String
    public static func fromMainBundle() throws -> AppEnvironment   // 缺键时抛错并写日志，不得回退到硬编码值
}
```

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

`project.yml` 骨架（随里程碑增补 target）：

```yaml
name: Aether
options:
  deploymentTarget:
    iOS: "17.0"
  createIntermediateGroups: true
  groupSortPosition: top
configFiles:
  Debug: Config/Base.xcconfig
  Release: Config/Base.xcconfig
settings:
  base:
    SWIFT_VERSION: "6.0"
packages:
  AetherKit:
    path: Packages/AetherKit
targets:
  Aether:
    type: application
    platform: iOS
    sources:
      - App/Sources
      - App/Resources
    info:
      path: App/Info.plist
      properties:
        CFBundleDisplayName: Aether
        UILaunchScreen: {}
        AetherAppGroupIdentifier: $(AETHER_APP_GROUP)
        AetherKeychainAccessGroup: $(AETHER_KEYCHAIN_GROUP)
        AetherTunnelBundleIdentifier: $(AETHER_BUNDLE_ID_PREFIX).tunnel
        AetherURLScheme: $(AETHER_URL_SCHEME)
        CFBundleURLTypes:
          - CFBundleURLSchemes: [$(AETHER_URL_SCHEME)]
    entitlements:
      path: App/Aether.entitlements
      properties:
        com.apple.developer.networking.networkextension: [packet-tunnel-provider]
        com.apple.security.application-groups: [$(AETHER_APP_GROUP)]
        keychain-access-groups: [$(AETHER_KEYCHAIN_GROUP)]
        com.apple.developer.networking.wifi-info: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $(AETHER_BUNDLE_ID_PREFIX)
    dependencies:
      - target: AetherTunnel
      - package: AetherKit
        # M5 起加入 AetherCertificates，M6 起加入 AetherScript（见 02 §3.2）
        products: [AetherProfile, AetherRules, AetherIPC, AetherStore, AetherControl]

  AetherTunnel:
    type: app-extension
    platform: iOS
    sources:
      - Tunnel/Sources
      - Tunnel/Resources
    info:
      path: Tunnel/Info.plist
      properties:
        CFBundleDisplayName: Aether Tunnel
        AetherAppGroupIdentifier: $(AETHER_APP_GROUP)
        AetherKeychainAccessGroup: $(AETHER_KEYCHAIN_GROUP)
        NSExtension:
          NSExtensionPointIdentifier: com.apple.networkextension.packet-tunnel
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).PacketTunnelProvider
    entitlements:
      path: Tunnel/AetherTunnel.entitlements
      properties:
        com.apple.developer.networking.networkextension: [packet-tunnel-provider]
        com.apple.security.application-groups: [$(AETHER_APP_GROUP)]
        keychain-access-groups: [$(AETHER_KEYCHAIN_GROUP)]
        com.apple.developer.networking.wifi-info: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $(AETHER_BUNDLE_ID_PREFIX).tunnel
    dependencies:
      - package: AetherKit
        products: [AetherEngine, AetherTunnelSupport, AetherScript, AetherIPC, AetherStore]

schemes:
  Aether:
    build:
      targets:
        Aether: all
        AetherTunnel: all
    run:
      config: Debug
    archive:
      config: Release
```

修改工程结构只改 `project.yml`，然后重新运行 `./Scripts/bootstrap.sh`。XcodeGen 语法以其官方文档为准；上面的骨架如与当前版本语法不符，以能生成可构建工程为准修正并更新本节。

## 5. 依赖

### 5.1 Swift 包

全部使用最新稳定主版本，`Package.resolved` 入库锁定。首次引入时把实际版本填入下表。

| 包 | 许可证 | 使用模块 | 用途 | 版本 |
| --- | --- | --- | --- | --- |
| apple/swift-nio | Apache-2.0 | Engine、Outbound、DNS、HTTP | 事件循环、Channel、HTTP/1、WebSocket | |
| apple/swift-nio-ssl | Apache-2.0 | Outbound、HTTP | TLS 客户端与服务端 | |
| apple/swift-nio-http2 | Apache-2.0 | HTTP | HTTP/2 MitM（M7）、DoH over h2 | |
| apple/swift-nio-extras | Apache-2.0 | HTTP | HTTP 压缩等辅助 Handler | |
| apple/swift-crypto | Apache-2.0 | Outbound、Certificates | AEAD、哈希、HKDF、密钥；`_CryptoExtras`（RSA 等） | |
| apple/swift-certificates | Apache-2.0 | Certificates | X.509 生成与签发（MitM） | |
| apple/swift-asn1 | Apache-2.0 | Certificates | swift-certificates 依赖 | |
| apple/swift-log | Apache-2.0 | 全部 | 日志门面 | |
| apple/swift-collections | Apache-2.0 | 全部 | `Deque`、`OrderedDictionary` | |
| apple/swift-atomics | Apache-2.0 | Engine | 原子引用、计数器 | |
| jpsim/Yams | MIT | Profile | 解析 YAML 格式的节点订阅 | |
| groue/GRDB.swift | MIT | Store | SQLite 访问 | |
| simonbs/Runestone | MIT | App（M4） | 配置文本编辑器（语法高亮、行号） | |

### 5.2 C 库

| 库 | 许可证 | 形式 | 用途 |
| --- | --- | --- | --- |
| heiher/hev-socks5-tunnel（含其子模块 lwIP、hev-task-system 等） | MIT（lwIP 为 BSD） | git submodule → xcframework | TUN ↔ SOCKS5 |
| BLAKE3 官方 C 实现 | CC0-1.0 / Apache-2.0 | 源码拷贝 | Shadowsocks 2022 密钥派生 |

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

- 以 git submodule 放在 `Vendor/hev-socks5-tunnel`，固定到一个发布 tag；升级时在提交说明中写明变更摘要。
- `Scripts/build-hev.sh`：
  1. `git submodule update --init --recursive`；
  2. 调用上游的 `build-apple.sh` 生成 `HevSocks5Tunnel.xcframework`（至少含 iOS 设备 arm64 与 iOS 模拟器切片）；
  3. 若产物不含 `module.modulemap`，补写一个暴露 `hev-main.h` 的模块映射，模块名 `CHevSocks5Tunnel`；
  4. 输出到 `Packages/AetherKit/Binaries/HevSocks5Tunnel.xcframework`；
  5. 在产物旁写 `VERSION`（submodule commit），脚本发现版本一致时跳过重复构建。
- CI 以 submodule commit 作为缓存键缓存该 xcframework。

### 6.2 BLAKE3

拷贝官方仓库 `c/` 目录中的可移植实现（`blake3.c`、`blake3_dispatch.c`、`blake3_portable.c` 与头文件）到 `Vendor/blake3`，并在 `Packages/AetherKit/Sources/CBlake3` 中以符号链接或拷贝引用。编译宏关闭所有 SIMD 分支（`BLAKE3_NO_SSE2`、`BLAKE3_NO_SSE41`、`BLAKE3_NO_AVX2`、`BLAKE3_NO_AVX512`、`BLAKE3_USE_NEON=0`），保证 Linux x86_64 与 iOS arm64 行为一致；它只用于每会话一次的密钥派生，性能足够。保留上游 LICENSE 与版本号文件。

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
| `release.yml` | `xcode-27` | 推送 `v*` tag | 见 §8.3 |

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
| Linux 容器 | `swift:6.4-noble`（Docker Hub 官方镜像） | 本地可用同名镜像复现：`docker run --rm -v "$PWD":/src -w /src/Packages/AetherKit swift:6.4-noble swift test` |
| Actions | `actions/checkout@v7`、`actions/cache@v6`、`actions/upload-artifact@v7` | |

`ios.yml` 的步骤随 M0 任务逐步补全：M0-05 只在 macOS 主机上运行架构检查与 `swift test`；M0-03 加入 hev 缓存与 `build-hev.sh`；M0-04 加入 XcodeGen 与 `xcodebuild build`。

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

`release.yml` 在 tag 推送时：

1. 与 `ios.yml` 相同的准备步骤，`-configuration Release`；
2. `xcodebuild archive` 生成 `Aether.xcarchive`；
3. 若仓库配置了签名机密（证书、描述文件、ExportOptions），用 `xcodebuild -exportArchive` 导出 `.ipa`；
4. 未配置签名机密时，以 `CODE_SIGNING_ALLOWED=NO` 归档，并把归档内的 `Aether.app` 按标准结构（`Payload/Aether.app`）打包为 `.ipa`，供后续签名流程使用；
5. 产物附带各 target 的 entitlements 文件与 `dSYM`，上传为 workflow artifact 并附到 GitHub Release；
6. Release 说明取 `CHANGELOG.md` 对应节。

## 9. 代码规范

- 格式：仓库根目录 `.swift-format`（4 空格缩进，行宽 120）。CI 以 `swift format lint --strict` 检查，lint 失败即失败；提交前可用 `swift format format -i --recursive Sources Tests` 自动修正。
- 架构约束：`Scripts/check-architecture.swift` 检查模块依赖方向（02 §3.2）、跨平台模块禁止的 import，以及 `project.yml` 中 App / 小组件不得依赖引擎相关模块；CI 在 Linux 与 macOS 上都运行它。新增模块时同时更新该脚本中的依赖图与 02 §3。
- 命名：类型 `UpperCamelCase`，协议描述能力（`OutboundConnector`、`ScriptRuntime`）；配置关键字与诊断码保持原文大小写。
- 访问控制：模块对外只暴露必要类型，默认 `internal`；跨模块 API 写文档注释。
- 禁止：`print`、`fatalError` / `try!` / 强制解包出现在数据面代码中（测试代码除外）；在 EventLoop 上阻塞；无上限的缓冲或集合；硬编码标识符；Apple 私有 API。
- 每个公开类型或重要算法附单元测试；协议实现附官方测试向量或互通测试（见 [13](13-testing.md)）。
