# Changelog

本文件记录 Aether 每个版本的变更。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)；里程碑与版本的对应见 [docs/01-product.md §5](docs/01-product.md#5-版本划分)。

## [Unreleased]

## [0.3.0] - 2026-10-30

M2：最小可用数据面。隧道接管全部流量，DIRECT / HTTP(S) / SOCKS5 出站按规则分流，App 可以导入配置、切换出站模式与策略、查看请求。

### Added

- 数据面：单 EventLoop 的流管理与胶水 Handler（背压、半关闭、双向空闲超时、并发上限）（M2-01）。
- DNS：报文编解码、Fake IP 池与跨重启快照、`[Host]`、缓存、UDP / TCP / system 上游、应答与路由解析（M2-02）。
- 入站：内部 SOCKS5（认证、CONNECT、UDP ASSOCIATE）与 HTTP 代理（CONNECT、绝对形式请求转发）（M2-03、M2-04）。
- 出站：DIRECT（Happy Eyeballs、NAT64 合成）、拒绝系列（含 DROP 升级）、HTTP / HTTPS、SOCKS5（含 UDP）、TLS 传输（指纹固定、跨平台一致的主机名校验）（M2-06）。
- `Router`：主机名恢复、嗅探（TLS SNI、HTTP Host）、出站模式、规则匹配与解析续算、策略解析、前置检查、请求记录（M2-05）。
- `select` 组与选择持久化、运行配置热替换（已有连接不中断）、`aether-cli run`（M2-07）。
- UDP 关联与 NAT 表：每目标独立路由、同策略共享出站关联、回包按 Fake IP 归属、block-quic、`udp-policy-not-supported-behaviour`；DNS 数据报分流（M2-08）。
- 统计：会话计数、1 Hz 采样、GRDB 数据库（`traffic_daily`、`logbook`）、迁移与保留策略（M2-12）。
- `AetherTunnelSupport`：完整隧道网络设置（IPv4 / IPv6、DNS、系统代理）、utun 描述符查找与 socketpair 备用桥接、hev 线程、路径监控与 SSID、libresolv 系统 DNS、`RLIMIT_NOFILE`（M2-09）。
- 隧道生命周期（启动、停止、重载、休眠唤醒）、状态快照与 Darwin 通知、内存压力处理、IPC 的 M2 命令（M2-10）。
- App 五个标签：首页（出站模式、流量曲线、常用策略组）、策略、请求与详情、配置（URL / 文件导入、提交运行包）、诊断；每个页面带 mock 预览（M2-11）。
- V02–V12 真机验收步骤（M2-13）。

### Changed

- 新增依赖：swift-nio、swift-nio-ssl、swift-certificates、GRDB（均为宽松许可证，已登记在 docs/03 §5.1）；Linux 构建需要 `libsqlite3-dev`。
- 新增 C 目标 `CAetherTunnel`（仅 Apple）与错误码 `NET-*`、`TLS-001`–`TLS-005`、`STO-002`、`STO-003`。
- macOS CI 的包测试改为先构建、再串行运行，并由看门狗在超时后打印线程调用栈。

### Fixed

- SOCKS5 UDP 关联在 Apple 平台上察觉不到服务器关闭控制连接（kqueue 只在有读取兴趣时报告 EOF）。

### 待真机验证

- V02–V12（步骤见 docs/13-testing.md §6.1）；hev 参数保持初值，待 V10 压测后回填 docs/06 §4.2。

## [0.2.0] - 2026-10-29

M1：配置内核。配置的解析、校验、模块叠加、编辑与规则引擎完整可用，不涉及网络。

### Added

- `AetherFoundation`：`IPAddress` / `CIDR` / `Hostname`（Punycode，RFC 3492 全部示例通过）/ `Endpoint`、有上限的 LRU、字节工具、cron 表达式；规则词汇类型下沉到此模块（M1-01、M1-07）。
- 无损配置模型 `ProfileDocument`：逐字节往返（BOM、CRLF、混合换行、无末尾换行）、带引号与括号深度的分词器、固定种子的模糊测试（M1-02）。
- 各节类型化解析与 04 §13 全部诊断码；语义校验（命名、引用、组循环、成员来源、FINAL）（M1-03、M1-04）。
- 模块：元数据、参数替换、按优先级叠加（`%APPEND%` / `%INSERT%`）；出错的模块整体不生效且不阻止配置提交；修订号（SHA-256）（M1-05）。
- 编辑操作（只改目标行）与脱敏渲染（M1-06）。
- 规则引擎：程序级域名索引、IP 区间表、关键字 Aho-Corasick、解析续算、`dns-failed`、追踪模式、决策缓存（M1-07）。
- 规则集 / 域名集加载、内置 `LAN`、编译缓存格式（M1-08）。
- `aether-cli check` / `match` / `render --redact`（M1-09）。
- 12 份兼容 fixtures 及期望摘要（M1-10）。
- `aether-bench` 与 CI 基准摘要（M1-11）。

### Changed

- 内置 `LAN` 规则集中的 IP 规则按 no-resolve 处理，避免为每个只有域名的流发起解析（05 §6.3）。
- 新增诊断码 `CFG-083`、`CFG-084` 与资源错误码 `RES-010`、`RES-011`。

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

[Unreleased]: https://github.com/mengangs/Aether/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/mengangs/Aether/releases/tag/v0.3.0
[0.2.0]: https://github.com/mengangs/Aether/releases/tag/v0.2.0
[0.1.0]: https://github.com/mengangs/Aether/releases/tag/v0.1.0
