# Changelog

本文件记录 Aether 每个版本的变更。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)；里程碑与版本的对应见 [docs/01-product.md §5](docs/01-product.md#5-版本划分)。

## [Unreleased]

## [0.1.0] - 2026-10-29

M0：工程骨架。工程能构建；App 能安装 VPN 配置并启动一个不接管流量的空隧道。

### Added

- 仓库初始化：开发文档与示例、目录结构、`.gitignore`、`.swift-format`、本变更日志（M0-01）。
- `AetherKit` 包骨架：全部模块的空壳与占位测试、Apple 专有模块的平台条件声明；架构约束检查脚本（M0-02）。
- CI：`core.yml`（Linux，Swift 6.4 容器）与 `ios.yml`（xcode-27 runner，macOS 测试与 iOS 构建）；失败时把编译与测试错误输出为注解（M0-05）。
- Vendored C 库：hev-socks5-tunnel 2.19.3（submodule，`build-hev.sh` 生成 xcframework）与 BLAKE3 1.8.7（`CBlake3`，官方测试向量全部通过）（M0-03）。
- XcodeGen 工程：App 与 Tunnel target、xcconfig、隐私清单、`bootstrap.sh`；标识符全部可由仓库变量覆盖（M0-04）。
- 发布工作流 `release.yml`：tag 与手动触发，产出未签名 ipa、展开后的 entitlements、标识符清单与 dSYM（M0-08）。
- `AppEnvironment`（缺键报 `IPC-020`）、Keychain 访问组前缀运行时探测、App Group 布局（不可用时 `STO-001` 错误页）；日志基础设施（os.Logger + 2 × 1 MiB 滚动文件）（M0-06）。
- 最小闭环：`TunnelController` 安装 / 启动 / 停止 VPN 配置，空隧道只路由 198.18.0.0/15、不改 DNS，IPC `getStatus` 往返，首页开关与连接时长（M0-07）。

### 待真机验证

- V01：首次安装 VPN 配置、拒绝授权后再次授权（步骤见 docs/13-testing.md §6.1）。

[Unreleased]: https://github.com/mengangs/Aether/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mengangs/Aether/releases/tag/v0.1.0
