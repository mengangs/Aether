# 10 控制与进程通信

本章定义 App、隧道、小组件之间的通信，以及外部控制入口（URL Scheme、快捷指令、HTTP 控制接口）。消息类型集中在 `AetherIPC` 模块，三方共用。

## 1. 通道

| 通道 | 方向 | 用途 |
| --- | --- | --- |
| `NETunnelProviderSession.sendProviderMessage` | App → 隧道（请求 / 响应） | 所有命令与查询 |
| Darwin 通知 | 隧道 → App、小组件 | "有变化"的信号，不带数据 |
| 状态快照文件 | 隧道写，App 与小组件读 | 小组件展示、App 冷启动时的初始状态 |
| App Group 文件 | 见 [11](11-storage.md) | 配置、资源、数据库 |
| `NETunnelProviderManager` / `NEVPNConnection` | App ↔ 系统 | 安装配置、启动、停止、状态 |

## 2. IPC 协议

### 2.1 信封

```swift
public struct IPCRequest: Codable, Sendable {
    public var version: Int = 1
    public let id: UUID
    public let command: IPCCommand          // 带关联值的枚举，Codable 编码为 {"type": "...", "params": {...}}
}

public struct IPCResponse: Codable, Sendable {
    public let version: Int
    public let id: UUID                     // 与请求相同
    public let outcome: Outcome             // .success(IPCPayload) / .failure(IPCError)
}

public struct IPCError: Error, Codable, Sendable {
    public let code: String                 // 如 "IPC-011"
    public let message: String              // 英文调试信息；界面文案由 App 按 code 本地化
    public let details: [String: String]?
}
```

- 编码：JSON（`JSONEncoder`，日期 ISO 8601，字节 Base64）。
- 版本：`version` 主版本不一致时隧道返回 `IPC-002`，App 提示重启隧道。
- 大小：响应负载应 < 256 KiB；列表类命令必须分页（`limit` 上限 200）。
- 超时：App 侧默认 5 秒；耗时操作（测速、资源更新）立即返回任务 ID，结果通过状态查询获取。
- 隧道收到无法解码的消息返回 `IPC-003`，不得崩溃。
- App 侧封装为 `AetherControl` 模块中的 `TunnelClient`（`actor`，App 与小组件共用），提供类型安全的 `async throws` 方法；隧道侧 `IPCDispatcher` 把命令分派给引擎，处理器在控制面执行。

### 2.2 命令

| 命令 | 参数 | 返回 | 里程碑 |
| --- | --- | --- | --- |
| `getStatus` | — | `TunnelStatus`（§3） | M0 |
| `getMemoryInfo` | — | footprint、可用额度、各组件估算、hev 统计 | M2 |
| `reloadProfile` | `expectedRevision` | 新修订号、诊断摘要 | M2 |
| `setOutboundMode` | `mode`：`rule` / `global` / `direct` | — | M2 |
| `setGlobalPolicy` | `policy` | — | M2 |
| `listPolicies` | — | 策略组（名称、类型、成员、当前选择、是否隐藏）与节点（名称、类型、能力、最近测速） | M2 |
| `selectPolicy` | `group`、`policy` | — | M2 |
| `getTraffic` | — | 会话总量、按节点与接口的总量、最近 120 个速率样本 | M2 |
| `getRequests` | `kind`：`recent` / `active`，`sinceID`，`limit` | `[RequestRecord]`、下一页游标 | M2 |
| `testPolicies` | `names?` 或 `group?`（都为空表示全部节点） | 任务 ID | M3 |
| `getTestResults` | `taskID?`、`since?` | 每个节点的延迟或错误、时间 | M3 |
| `matchRule` | 主机或 URL、端口、协议、可选网络环境 | `RuleTrace`（[05 §8.2](05-rule-engine.md#82-规则测试工具)） | M3 |
| `updateResources` | `ids?` | 任务 ID（隧道自行下载） | M3 |
| `resourcesChanged` | `ids` | —（App 已更新缓存，隧道重新加载） | M3 |
| `getDNSCache` / `getFakeIPMappings` | `offset`、`limit` | 列表 | M3 / M4 |
| `flushDNS` | — | — | M3 |
| `testDNSUpstreams` | — | 每个上游的耗时或错误 | M4 |
| `queryDNS` | `name`、`type` | 答案与处理路径 | M4 |
| `killRequest` / `killAllRequests` | `id` / — | — | M4 |
| `getLogs` | `sinceSeq`、`limit`、`minLevel` | 日志行 | M4 |
| `setLogLevel` | `level`、`duration?`（到期自动恢复） | — | M4 |
| `clearData` | `kinds`：`traffic` / `requestHistory` / `logbook` / `capture` | — | M4 |
| `setFeature` | `feature`：`mitm` / `rewrite` / `scripting` / `capture`，`enabled` | — | M5 / M6 |
| `reloadCA` | — | — | M5 |
| `getRequestDetail` | `id` | 记录 + 抓包条目列表 | M5 |
| `getCaptureBody` | `captureID`、`part`：`request` / `response`、`offset`、`limit` | 字节块（Base64） | M5 |
| `evaluateScript` | 源码、模拟类型与数据、`argument`、`timeout` | `ScriptOutcome` | M6 |
| `runScript` | `name`、`parameter?` | `ScriptOutcome` | M6 |
| `getScriptStore` | `prefix?`、`offset`、`limit` | 键值列表 | M6 |
| `setScriptStoreValue` | `key`、`value?`（为空即删除） | — | M6 |

隧道未运行时，`TunnelClient` 直接抛出 `IPC-001`，界面据此显示"未连接"状态，不弹错误。

### 2.3 IPC 错误码

| 码 | 含义 |
| --- | --- |
| `IPC-001` | 隧道未运行或会话不可用 |
| `IPC-002` | 协议版本不一致 |
| `IPC-003` | 消息无法解码 |
| `IPC-004` | 超时 |
| `IPC-005` | 负载过大 |
| `IPC-010` | 没有可用配置（Active Bundle 不存在） |
| `IPC-011` | 参数无效（如不存在的策略组或成员） |
| `IPC-012` | 当前状态不允许该操作（如启动中） |

## 3. 状态快照

隧道写 `State/tunnel-status.json`（原子写），也作为 `getStatus` 的返回结构：

```json
{
  "schemaVersion": 1,
  "writer": "tunnel",
  "state": "running",
  "since": "2026-10-30T08:00:00Z",
  "updatedAt": "2026-10-30T08:05:30Z",
  "profile": { "id": "6F1C…", "name": "Main", "revision": "sha256:…" },
  "outboundMode": "rule",
  "globalPolicy": "Proxy",
  "features": { "mitm": false, "rewrite": true, "scripting": true, "capture": false },
  "network": { "interfaceType": "wifi", "ssid": "Home", "revision": 12 },
  "traffic": { "upBps": 1234, "downBps": 56789, "sessionUpBytes": 1048576, "sessionDownBytes": 73400320 },
  "primaryGroups": [ { "name": "Proxy", "current": "HK-01", "latencyMs": 120 } ],
  "alerts": [ { "code": "MITM-002", "severity": "warning" } ],
  "lastError": null
}
```

- 写入时机：状态、配置、出站模式、功能开关、策略选择变化时立即写；运行中每 30 秒刷新一次流量字段（供小组件使用）。
- `primaryGroups`：配置中前 3 个非隐藏的 `select` 组。
- 例外写者：隧道异常退出时文件可能停在 `running`。App 观察到 `NEVPNStatus` 为已断开且快照 `writer == "tunnel"`、`state != "idle"` 时，改写为 `{"writer": "app", "state": "idle", …}`。这是单写者原则唯一的例外。
- 写入后发出 Darwin 通知 `<Bundle ID 前缀>.notify.status`。另有 `<Bundle ID 前缀>.notify.logbook`（新增日志簿事件）。

App 在前台时以 1 Hz 调用 `getStatus` 与 `getTraffic` 刷新首页；进入后台停止轮询。

## 4. 隧道管理（App 侧）

`TunnelController`（`AetherControl` 模块，`@MainActor`，App 与小组件 / Intent 共用）：

1. `NETunnelProviderManager.loadAllFromPreferences()`，找到 `providerBundleIdentifier` 等于 `AppEnvironment.tunnelBundleIdentifier` 的配置；没有则创建：`localizedDescription = "Aether"`，协议设置见 [06 §3](06-network-engine.md#3-隧道网络设置)，`isEnabled = true`。
2. `saveToPreferences()`（首次会弹出系统授权"添加 VPN 配置"），随后**必须**再 `loadFromPreferences()` 才能启动。
3. 启动前确认 Active Bundle 已提交；`connection.startVPNTunnel(options: ["source": "app"])`。
4. 停止：`connection.stopVPNTunnel()`。若按需连接已开启，先把 `isOnDemandEnabled` 设为 `false` 并保存，否则系统会立即重连；界面提示"按需连接已暂停"。
5. 监听 `NEVPNStatusDidChange`，映射为界面状态：未安装 / 已断开 / 连接中 / 已连接 / 重新连接中 / 断开中。
6. 授权被拒、配置失效时给出明确说明与"重新安装 VPN 配置"按钮。

按需连接（M4）：

| 设置 | 规则 |
| --- | --- |
| 关闭 | `isOnDemandEnabled = false` |
| 始终连接 | `NEOnDemandRuleConnect`，`interfaceTypeMatch = .any` |
| 自定义 | 若干受信任 SSID → `NEOnDemandRuleDisconnect`；其余 Wi-Fi 与蜂窝 → `NEOnDemandRuleConnect` |

## 5. URL Scheme

Scheme 来自 `AppEnvironment.urlScheme`（默认 `aether`）。

| URL | 行为 |
| --- | --- |
| `aether://start`、`aether://stop`、`aether://toggle` | 启动 / 停止 / 切换隧道 |
| `aether://set-mode?mode=rule\|global\|direct` | 切换出站模式 |
| `aether://select-policy?group=<组>&policy=<策略>` | 选择节点 |
| `aether://switch-profile?name=<配置名>` | 切换配置并重载 |
| `aether://install-config?url=<URL 编码>&name=<可选>` | 下载配置，进入导入确认页 |
| `aether://install-module?url=<URL 编码>` | 下载模块，进入安装确认页 |
| `aether://run-script?name=<脚本名>&parameter=<可选>` | 运行 generic 脚本，显示结果 |

- 安装类 URL **总是**进入确认页：显示来源 URL、内容预览、诊断摘要；用户确认后才写入。
- 参数缺失或无效时显示错误提示，不做任何更改。

## 6. HTTP 控制接口（M7）

为外部面板、自动化工具和 `$httpAPI` 提供的 REST 接口，与 IPC 命令一一对应，由隧道内的 HTTP 服务实现。

- 监听：`http-api = 密钥@地址:端口`（默认端口 6170），默认只绑定 `127.0.0.1`；`http-api-tls = true` 时使用由 Aether CA 签发的证书。
- 认证：请求头 `X-Key: <密钥>` 或 `Authorization: Bearer <密钥>`；失败返回 `401`。同一来源 IP 每分钟失败超过 10 次返回 `429`。
- 格式：请求与响应为 JSON；`GET` 参数用查询串；请求必须带 `Content-Length`（不接受分块，返回 `411`），Body 上限 1 MiB（超出 `413`）。
- 错误：`{"error": {"code": "IPC-011", "message": "..."}}`，HTTP 状态按错误类型映射（400 / 404 / 409 / 500）。
- CORS：默认不返回 CORS 头。

| 方法 | 路径 | 对应命令 |
| --- | --- | --- |
| GET | `/v1/status` | `getStatus` |
| GET / PUT | `/v1/outbound` | 读取 / `setOutboundMode`（`{"mode": "rule"}`） |
| GET / PUT | `/v1/outbound/global` | 读取 / `setGlobalPolicy` |
| GET / PUT | `/v1/features/{mitm\|rewrite\|scripting\|capture}` | 读取 / `setFeature`（`{"enabled": true}`） |
| GET | `/v1/policies` | `listPolicies` |
| PUT | `/v1/policy-groups/{组名}/selection` | `selectPolicy`（`{"policy": "HK-01"}`） |
| POST | `/v1/policies/test` | `testPolicies` |
| GET | `/v1/policies/test-results` | `getTestResults` |
| GET | `/v1/requests?kind=recent&since=&limit=` | `getRequests` |
| DELETE | `/v1/requests/{id}` | `killRequest` |
| GET | `/v1/traffic` | `getTraffic` |
| GET | `/v1/dns/cache` | `getDNSCache` |
| POST | `/v1/dns/flush` | `flushDNS` |
| POST | `/v1/profiles/reload` | `reloadProfile` |
| GET | `/v1/profiles/current` | 当前配置文本，默认脱敏；`?redact=false` 需在设置中额外允许 |
| POST | `/v1/scripts/evaluate` | `evaluateScript` |
| POST | `/v1/scripts/{名称}/run` | `runScript` |
| GET | `/v1/logs?since=&limit=` | `getLogs` |
| GET | `/v1/metrics` | Prometheus 文本格式（`text/plain; version=0.0.4`），不是 JSON |
| GET | `/v1/mitm/ca` | CA 证书 DER（`application/x-x509-ca-cert`），不含私钥 |

路径中的组名、脚本名做 URL 解码。

## 7. 快捷指令（App Intents，M4）

| Intent | 参数 | 实现 |
| --- | --- | --- |
| `StartTunnelIntent` / `StopTunnelIntent` / `ToggleTunnelIntent` | — | `TunnelController` |
| `SetOutboundModeIntent` | 模式（AppEnum） | IPC `setOutboundMode` |
| `SelectPolicyIntent` | 策略组（AppEntity）、策略（依赖策略组的 AppEntity） | IPC `selectPolicy` |
| `SwitchProfileIntent` | 配置（AppEntity） | 提交 Active Bundle + `reloadProfile` |
| `SetFeatureIntent` | 功能（AppEnum）、开 / 关 | IPC `setFeature` |
| `UpdateResourcesIntent` | — | App 下载 + IPC `updateResources` |
| `RunScriptIntent` | 脚本（AppEntity，仅 generic 类型）、参数文本 | IPC `runScript`，返回 `content` 文本 |

- Intent 源码同时编入 App 与小组件 target，`openAppWhenRun = false`。
- 实体查询读取状态快照与 App Group 中的配置索引，隧道未运行时策略组列表来自最近一次的快照。
- 🔬 需验证在小组件 / 控制中心进程中执行时能否访问 `NETunnelProviderManager` 并启动隧道；不能时改为需要打开 App 的形式（`ForegroundContinuableIntent`），并在本节记录结论。
