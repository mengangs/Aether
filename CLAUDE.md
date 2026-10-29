# CLAUDE.md

本文件是在本仓库中工作的约定，每次开始工作前先读一遍。

## 项目

Aether：iOS 上基于规则的网络代理客户端（Packet Tunnel + 自研 Swift 网络引擎）。设计文档在 `docs/`，入口是 [docs/README.md](docs/README.md)。**文档是实现依据**；实现中发现文档有误或需要调整，在同一个提交中修改文档并在提交说明里写清原因。

## 开始一项工作

1. 打开 [docs/14-roadmap.md](docs/14-roadmap.md)，确定要做的任务（用户指定的，或当前里程碑中第一个未完成且依赖已满足的任务）。进度只以 roadmap 中的任务状态为准，不要重复已完成（`[x]`）的任务。
2. 读该任务"参考"列中的章节，以及 [docs/02-architecture.md](docs/02-architecture.md) 的模块边界（§3）与内存预算（§6）。
3. 直接在 `main` 上开发，不建功能分支、不开 PR。
4. 实现 + 测试 + 文档同步；在 roadmap 中把任务状态改为 `[x]`。
5. 提交信息用 Conventional Commits 并带任务编号，例如 `feat(engine): [M2-06] SOCKS5 outbound`（scope 见 [docs/03-project-setup.md §8.2](docs/03-project-setup.md#82-分支与提交)）。
6. 推送到 `main`，查看 CI 结果。每次推送后 CI 必须通过；失败时优先修复，修到通过后再开始下一个任务。

一个提交（或一组连续提交）只做一个任务。任务太大时先在 roadmap 中拆分并说明。

## 构建与测试

```bash
# 跨平台核心库（Linux 或 macOS）
cd Packages/AetherKit
swift build
swift test --parallel
swift format lint --strict --recursive Sources Tests

# 架构约束（依赖方向、跨平台模块禁止的 import、App 不得依赖引擎），在仓库根目录运行
swift Scripts/check-architecture.swift .

# 开发调试 CLI
swift run aether-cli check ../../examples/full.conf
swift run aether-cli match ../../examples/full.conf --host www.example.com --port 443

# iOS 工程（仅 macOS）
./Scripts/bootstrap.sh
xcodebuild build -project Aether.xcodeproj -scheme Aether \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
```

- Linux 上用 swiftly 安装 Swift 6.x 工具链即可构建、测试所有"全部平台"模块。
- `AetherScript`、`AetherTunnelSupport` 与 App / 扩展 target 只能在 macOS 上编译。修改它们后推送 `main`，用 `gh run watch` 查看 `ios.yml` 结果，CI 失败要修到通过为止。
- 不要提交生成的 `Aether.xcodeproj`；工程结构只改 `project.yml`。

## 代码约定

- Swift 6 语言模式，完整并发检查。数据面绑定 EventLoop，控制面用 `actor`（[02 §7](docs/02-architecture.md#7-线程与并发)）。
- 跨平台模块不得 `import` UIKit、SwiftUI、NetworkExtension、JavaScriptCore、CryptoKit、Network、Security；加密用 swift-crypto。
- 模块依赖方向见 [02 §3.2](docs/02-architecture.md#32-依赖方向)，不得反向依赖。App 与小组件不得直接或间接依赖 `AetherEngine`、`AetherOutbound`、`AetherHTTP`。
- 标识符（Bundle ID、App Group、Keychain 组、URL Scheme）只从 `AppEnvironment` 读取，不得硬编码。
- 数据面代码中禁止 `print`、`try!`、`fatalError`、强制解包；用 swift-log 记录日志，遵守 [02 §8.2](docs/02-architecture.md#82-日志) 的脱敏规则。
- 任何缓冲、队列、缓存、集合都必须有上限，并在文档注释中写明溢出时的行为。
- 错误使用带稳定错误码的类型（`CFG-`、`NET-`、`DNS-`、`TLS-`、`MITM-`、`SCR-`、`IPC-`、`RES-`、`STO-`）；新增错误码同时加到对应文档的错误码表。
- 新增依赖前按 [03 §5.3](docs/03-project-setup.md#53-引入新依赖的检查) 检查许可证，只允许宽松许可证（ADR-009），并更新依赖表。
- 不使用 Apple 私有 API。
- SwiftUI 页面必须提供使用 `MockTunnelClient` 的 `#Preview`（含空状态与错误状态）。

## 测试约定

- Swift Testing（`@Test`、`#expect`）。测试数据放 `Tests/Fixtures/`。
- 测试不访问公网。示例与测试中的域名用 `example.com` / `example.net` / `example.org`，地址用文档保留段（`192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`、`2001:db8::/32`）。
- 协议实现必须有测试向量或互通测试（[13 §3](docs/13-testing.md#3-互通测试)）。
- 时间与随机数通过注入控制，测试不依赖真实时间流逝。

## 待真机验证的设计点

文档中标 🔬 的设计依赖真机行为。实现时：按文档方案实现；能做回退的就做好回退与开关；在 [13 §6](docs/13-testing.md#6-真机验收矩阵) 对应行保持"待验证"。不要在文档或提交说明中声称已经在真机上验证过，除非有记录。

## 不要做

- 不要提交任何密钥、真实节点、个人订阅地址、证书私钥。
- 不要为了让测试通过而修改测试的期望值，除非确认是期望值错了，并在提交说明中写清原因。
- 不要静默忽略配置中的未知内容——保留原文并给出诊断。
- 不要实现 [01 §4](docs/01-product.md#4-非目标) 中的非目标。
- 不要在一个任务的提交中混入与任务无关的重构。
