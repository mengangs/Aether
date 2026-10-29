# Aether

**Every packet, its own path.** · 每个数据包，都有自己的路

A rule-based network proxy client for iOS, with flexible routing, MitM, and scripting.

---

## About

Aether is a rule-based network proxy client for iOS. Named after the medium once believed to carry light, and the origin of the word "Ethernet", it quietly carries your traffic exactly where it should go.

- **Flexible routing** — route by domain, IP, GeoIP, or rule sets
- **Policy groups** — auto-select, fallback, and load-balance across nodes
- **MitM & rewrite** — inspect and modify HTTPS requests and responses
- **Scripting** — extend behavior with JavaScript
- **Lightweight** — tuned for the memory limits of iOS Network Extension

## 简介

Aether 是一款基于规则的 iOS 网络代理客户端。它的名字来自以太，那种古人相信承载着光的介质，也是"以太网"一词的源头。它安静地把每一份流量，送到该去的地方。

- **灵活分流**：按域名、IP、GeoIP、规则集精准路由
- **策略组**：自动测速、故障转移、负载均衡
- **MitM 与重写**：解密并改写 HTTPS 请求与响应
- **脚本扩展**：用 JavaScript 自定义行为
- **轻量**：专为 iOS Network Extension 的内存限制优化

> 功能列表以实际实现为准。每个里程碑结束时，按 [docs/14-roadmap.md](docs/14-roadmap.md) 的完成情况同步更新本节和仓库描述。

---

## 状态

开发中。当前里程碑见 [docs/14-roadmap.md](docs/14-roadmap.md)。

## 系统要求

| 项目 | 要求 |
| --- | --- |
| 运行 | iOS / iPadOS 17.0 及以上，arm64 |
| 开发 | Xcode 27（Swift 6.4）；Xcode 26.x 亦可构建 |
| 核心库 | Swift 6.x 工具链，macOS 或 Linux 均可构建与测试 |

## 快速开始

```bash
git clone --recursive <repo-url> Aether
cd Aether

# 核心库（macOS / Linux）
cd Packages/AetherKit && swift build && swift test && cd -

# iOS 工程（macOS）
brew install xcodegen
cp Config/Local.xcconfig.example Config/Local.xcconfig   # 填入自己的 Team 与 Bundle ID 前缀
./Scripts/bootstrap.sh                                   # 编译 vendored C 库并生成 Aether.xcodeproj
open Aether.xcodeproj
```

完整说明见 [docs/03-project-setup.md](docs/03-project-setup.md)。

## 文档

从 [docs/README.md](docs/README.md) 开始阅读。开发约定见 [CLAUDE.md](CLAUDE.md)。

## 许可证

待定。项目只引入 MIT / BSD / Apache-2.0 / ISC / CC0 等宽松许可证的依赖，以保留许可证选择的自由，详见 [docs/03-project-setup.md](docs/03-project-setup.md#5-依赖)。
