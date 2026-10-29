# 11 存储与数据模型

## 1. 存储位置

| 位置 | 内容 | 访问者 |
| --- | --- | --- |
| App Group 容器 `Aether/` 目录 | 配置、模块、脚本、外部资源、运行包、状态、数据库、日志、抓包 | App、隧道、小组件（只读部分） |
| Keychain 共享访问组 | MitM CA、HTTP 控制接口密钥 | App、隧道 |
| App 沙盒 `Library/Caches` | 只属于 App 的临时数据（编辑器草稿、下载临时文件） | App |
| `UserDefaults`（App 自身） | 纯界面偏好（上次打开的标签页、列表排序） | App |

跨进程共享的状态**不得**放在 `UserDefaults(suiteName:)` 中：它没有原子的多键更新，也不便于单写者控制。全部用 App Group 中的文件或数据库。

## 2. 单写者归属

| 数据 | 隧道运行时由谁写 | 隧道未运行时由谁写 |
| --- | --- | --- |
| 配置与配置索引（`Profiles/`） | App | App |
| 模块与模块索引（`Modules/`） | App | App |
| 本地脚本（`Scripts/`） | App | App |
| 运行包（`Bundles/`、`active.json`） | App | App |
| 外部资源缓存（`Resources/`） | App 与隧道（见下） | App |
| 出站模式、全局策略、功能开关（`State/runtime.json`） | 隧道（App 经 IPC 请求） | App |
| 策略组选择（`State/selections.json`） | 隧道（App 经 IPC 请求） | App |
| Fake IP 快照（`State/fakeip.bin`） | 隧道 | — |
| 状态快照（`State/tunnel-status.json`） | 隧道 | App（仅在隧道异常退出后改写为 idle，见 [10 §3](10-control-ipc.md#3-状态快照)） |
| 数据库（`Database/`） | 隧道（App 的清除统计、编辑脚本存储经 IPC `clearData`、`setScriptStoreValue` 请求） | App（仅上述用户操作） |
| 日志（`Logs/`） | 隧道写 `tunnel.*.log`，App 写 `app.*.log` | 同左 |
| 抓包（`Capture/`） | 隧道 | App（仅删除） |

外部资源缓存是唯一允许两个写者同时存在的地方：每个资源的数据文件与元数据文件各自原子替换，内容各自自洽；两方并发下载同一资源时，后完成者覆盖，结果同样有效。

"隧道是否运行"以 App 观察到的 `NEVPNStatus` 为准；状态处于连接中 / 断开中时，App 推迟写入直到状态稳定。

## 3. 文件布局

```text
<App Group>/Aether/
├── Profiles/
│   ├── index.json                 # [ProfileEntry]
│   └── <uuid>.conf
├── Modules/
│   ├── index.json                 # [ModuleEntry]，数组顺序即叠加顺序
│   └── <uuid>.amodule
├── Scripts/                       # 本地脚本，配置中的相对路径以此为基准
├── Resources/
│   ├── <key>.data                 # key = SHA-256(规范化 URL) 的前 32 个十六进制字符
│   ├── <key>.meta.json
│   └── <key>.ruleset.bin          # 规则集编译缓存（05 §6.4）
├── Bundles/
│   └── <修订号前 16 位>/
│       ├── manifest.json
│       ├── profile.conf
│       └── modules/<序号>-<uuid>.amodule
├── active.json                    # 指向当前运行包
├── State/
│   ├── runtime.json
│   ├── selections.json
│   ├── fakeip.bin
│   └── tunnel-status.json
├── Database/
│   └── aether.sqlite（及 -wal、-shm）
├── Logs/
├── Capture/
└── Inbox/                         # M7 分享扩展的导入收件箱
```

### 3.1 索引结构

```swift
public struct ProfileEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String                 // 显示名，可重命名，与文件名无关
    public var source: Source               // .local / .managed(url, interval, strict) / .imported(url)
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUpdateAttemptAt: Date?   // 托管配置
    public var lastUpdateError: String?
    public var revision: String             // 文件内容 SHA-256
}

public struct ModuleEntry: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String                 // 取自 #!name
    public var enabled: Bool
    public var sourceURL: URL?              // 远程模块按资源规则更新
    public var arguments: [String: String]  // 用户填写的参数值
    public var updatedAt: Date
    public var lastError: String?
}
```

当前选中的配置由 `active.json` 指向的运行包清单中的 `profileID` 决定（App 拥有），不另外存储。

### 3.2 运行状态

```json
{
  "schemaVersion": 1,
  "outboundMode": "rule",
  "globalPolicy": "Proxy",
  "features": { "mitm": false, "rewrite": true, "scripting": true, "capture": false }
}
```

`selections.json`：`{"schemaVersion": 1, "selections": {"<profileID>": {"<组名>": "<成员名>"}}}`。

所有 JSON 文件都带 `schemaVersion`。读方遇到更高版本时按只读方式尽力解析并记录警告；写方总是写当前版本。

## 4. 数据库

GRDB `DatabasePool`（WAL 模式），位于 App Group。

### 4.1 表

```sql
CREATE TABLE traffic_daily (
  day TEXT NOT NULL,              -- 本地日期 YYYY-MM-DD
  policy TEXT NOT NULL,           -- 最终节点名
  interface TEXT NOT NULL,        -- wifi / cellular / wired / other
  up INTEGER NOT NULL DEFAULT 0,
  down INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, policy, interface)
);

CREATE TABLE traffic_host_daily (
  day TEXT NOT NULL,
  host TEXT NOT NULL,
  policy TEXT NOT NULL,
  up INTEGER NOT NULL DEFAULT 0,
  down INTEGER NOT NULL DEFAULT 0,
  requests INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (day, host, policy)
);

CREATE TABLE request_history (
  id TEXT PRIMARY KEY,            -- <隧道会话 UUID>-<序号>
  started_at REAL NOT NULL,
  ended_at REAL,
  inbound TEXT NOT NULL,
  transport TEXT NOT NULL,
  app_protocol TEXT NOT NULL,
  host TEXT,
  destination TEXT NOT NULL,
  method TEXT,
  url TEXT,
  status INTEGER,
  rule TEXT,
  policy_chain TEXT NOT NULL,     -- JSON 数组
  mitm INTEGER NOT NULL,
  bytes_up INTEGER NOT NULL,
  bytes_down INTEGER NOT NULL,
  state TEXT NOT NULL,
  error_code TEXT,
  notes TEXT                      -- JSON 数组
);
CREATE INDEX request_history_started ON request_history (started_at);

CREATE TABLE rule_usage (
  rule_key TEXT PRIMARY KEY,      -- 来源 + 规范化原文的哈希
  rule_text TEXT NOT NULL,
  source TEXT NOT NULL,
  hits INTEGER NOT NULL DEFAULT 0,
  last_hit_at REAL NOT NULL
);

CREATE TABLE logbook (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at REAL NOT NULL,
  level TEXT NOT NULL,            -- info / warning / error
  category TEXT NOT NULL,         -- tunnel / profile / resource / memory / mitm / script
  code TEXT,                      -- 错误码
  message TEXT NOT NULL,
  details TEXT                    -- JSON
);

CREATE TABLE script_store (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at REAL NOT NULL
);
```

### 4.2 保留策略

| 表 | 保留 |
| --- | --- |
| `traffic_daily` | 400 天 |
| `traffic_host_daily` | 30 天 |
| `request_history` | 仅在设置中开启"保存请求历史"时写入；7 天或 20,000 行，先到为准 |
| `rule_usage` | 90 天未命中的行删除 |
| `logbook` | 30 天或 5,000 行 |
| `script_store` | 不自动删除，受 [09 §8](09-scripting.md#8-persistentstore) 的容量上限约束 |

隧道每次启动时及每 6 小时执行一次清理。

### 4.3 迁移

- 使用 GRDB `DatabaseMigrator`；迁移只追加、按名称标识（`v1_initial`、`v2_…`），发布后不得修改。
- App 与隧道打开数据库时都运行迁移器（幂等）。

### 4.4 进程挂起与文件锁

App 进入后台时若仍持有 App Group 中 SQLite 的锁，可能被系统终止。要求：

- App 侧开启 GRDB 的 `observesSuspensionNotifications`，在场景进入后台时发送 `Database.suspendNotification`，回到前台时发送 `Database.resumeNotification`；
- App 侧只做短事务，不在后台任务中长时间读写数据库；
- 隧道侧写入批量合并、单事务内完成。

### 4.5 数值

字节计数一律 64 位整数。IPC 的 JSON 中以数字传输（Swift `UInt64` 编解码无精度问题）；HTTP 控制接口面向 JavaScript 客户端时，超过 2⁵³ 的值另以字符串字段提供（如 `upBytesString`）。

## 5. 外部资源

### 5.1 种类

| 种类 | 来源 | 校验 | 大小上限 |
| --- | --- | --- | --- |
| 规则集 / 域名集 | `RULE-SET`、`DOMAIN-SET` | 至少 1 条有效条目 | 32 MiB |
| 节点订阅 | `policy-path` | 至少 1 个可解析节点 | 32 MiB |
| 远程脚本 | `script-path` | 非空 UTF-8 文本 | 4 MiB |
| MMDB | `geoip-db-url`、`ipasn-db-url` | 元数据有效 | 64 MiB |
| Map Local 文件 | `data-type=file` 的 URL | 无 | 8 MiB |
| 托管配置 | `#!MANAGED-CONFIG` | 解析无 error 级诊断 | 4 MiB |
| 远程模块 | 模块的来源 URL | 解析无 error 级诊断 | 4 MiB |

托管配置与远程模块下载后写入 `Profiles/`、`Modules/`（只由 App 更新），其余写入 `Resources/`。

### 5.2 元数据

```json
{
  "schemaVersion": 1,
  "url": "https://example.com/rules/ads.list",
  "kind": "ruleSet",
  "fetchedAt": "2026-10-30T08:00:00Z",
  "lastAttemptAt": "2026-10-30T08:00:00Z",
  "lastError": null,
  "etag": "\"abc\"",
  "lastModified": "Thu, 29 Oct 2026 10:00:00 GMT",
  "sha256": "…",
  "size": 123456,
  "updateInterval": 86400
}
```

### 5.3 下载

- 请求头 `User-Agent: Aether/<版本>`；带 `If-None-Match` / `If-Modified-Since` 条件请求，`304` 只更新 `fetchedAt`。
- 超时 20 秒；按扩展名 `.gz` 或魔数 `1f 8b` 自动解压。
- 校验通过后才原子替换缓存；失败保留旧缓存，记录 `lastError` 并写日志簿（`RES` 类错误码）。
- 失败重试按指数退避：5 分钟起，上限 1 小时。
- App 使用 `URLSession`（隧道运行时，App 自身的请求会按规则经过隧道）。隧道使用引擎自己的 HTTP 客户端，出站策略由 `[General] resource-fetch-policy` 决定（默认 `DIRECT`）。

### 5.4 调度

| 场景 | 行为 |
| --- | --- |
| 导入配置或模块 | App 立即下载其引用的全部资源（展示进度），失败的资源不阻止提交 |
| App 启动、回到前台 | 后台线程检查到期资源并更新 |
| 后台刷新 | `BGAppRefreshTask`，最早执行时间 = 最近的到期时间；每次最多处理 30 秒 |
| 隧道运行中 | 每 15 分钟检查到期资源并更新；成功后去抖 10 秒合并重载运行配置 |
| App 更新了运行中配置引用的资源 | IPC `resourcesChanged(ids)`，隧道重新加载 |
| 用户手动"全部更新" | App 下载 + 隧道运行时 IPC `updateResources` |

## 6. 提交运行包

1. App 读取选中配置与已启用模块，解析叠加得到 `ResolvedProfile`；存在 error 级诊断则中止，展示诊断。
2. 在 `Bundles/` 下以修订号前 16 位为名创建新目录（已存在则复用），写入 `profile.conf`、各模块文件（参数值已代入）与 `manifest.json`。
3. 原子替换 `active.json`：`{"schemaVersion": 1, "revision": "…", "bundle": "Bundles/<目录名>", "committedAt": "…"}`。
4. 隧道运行时发送 IPC `reloadProfile(expectedRevision)`。
5. 清理：保留最近 3 个运行包目录，删除更早且不被 `active.json` 引用的目录。

`manifest.json`：

```json
{
  "schemaVersion": 1,
  "revision": "sha256:…",
  "profileID": "6F1C…",
  "profileName": "Main",
  "committedAt": "2026-10-30T08:00:00Z",
  "appVersion": "0.3.0 (412)",
  "modules": [ { "id": "…", "name": "示例模块", "file": "modules/01-….amodule" } ]
}
```

本地脚本与外部资源不复制进运行包，隧道直接读取 `Scripts/` 与 `Resources/`。

## 7. 数据保护与备份

- App Group 中的文件使用默认数据保护级别 `completeUntilFirstUserAuthentication`。设备重启后首次解锁前隧道无法读取配置，此时启动失败并返回明确错误。
- `Resources/`、`Bundles/`、`Logs/`、`Capture/` 设置 `isExcludedFromBackup`（可重新获取或不应备份）。配置、模块、脚本、数据库随系统备份。
- Keychain 中的 CA 为 `ThisDeviceOnly`，不随备份迁移；在新设备上需要重新生成或从备份文件导入（[08 §2.5](08-mitm-rewrite.md#25-重新生成导入与导出)）。

## 8. 导出与分享

| 对象 | 格式 | 默认 |
| --- | --- | --- |
| 配置 | `.conf` 文本 | 脱敏（[04 §15.2](04-profile-spec.md#152-编辑)），可选"包含敏感信息" |
| 模块 | `.amodule` | 原样 |
| 请求 / 抓包 | HAR、cURL、文本 | 敏感头脱敏 |
| 日志 | `.log` 文本打包为 zip | 已在写入时排除敏感信息 |
| 诊断包 | zip：日志、日志簿、状态快照、内存信息、脱敏后的当前配置 | 需用户确认内容后导出 |
