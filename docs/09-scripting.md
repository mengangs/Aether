# 09 脚本

`AetherScriptCore` 定义 `ScriptRuntime` 与 `ScriptHostServices` 协议；`AetherScript` 用 JavaScriptCore 实现运行时；`AetherHTTP` 在 HTTP 管线中调用，引擎负责 cron 与事件触发。配置语法见 [04 §10](04-profile-spec.md#10-script)。里程碑：M6（`dns`、`rule` 类型与 `$httpAPI` 在 M7）。

## 1. 兼容目标

主流客户端的脚本接口事实上已形成通用约定（`$request`、`$response`、`$done`、`$httpClient`、`$persistentStore`、`$notification` 等）。Aether 实现这套接口，使以"检测 API 是否存在"方式编写的跨客户端脚本无需修改即可运行。Aether 不伪装成其它客户端（`$environment` 中只提供 Aether 自己的版本键）。

## 2. 脚本类型与触发

| 类型 | 触发 | 输入 | `$done` 的含义 |
| --- | --- | --- | --- |
| `http-request` | HTTP 可见的请求，URL 匹配 `pattern` | `$request` | 见 §5.2 |
| `http-response` | HTTP 可见的响应，请求 URL 匹配 `pattern` | `$request`、`$response` | 见 §5.3 |
| `cron` | 隧道运行期间按 `cronexp`（设备本地时区）触发 | — | 结束执行；值被忽略 |
| `event` | `network-changed`：网络修订号变化后去抖 2 秒 | `$event = {name, data}` | 结束执行 |
| `generic` | App 中手动运行、快捷指令"运行脚本"、`aether://run-script?name=…` | `$intent.parameter`（字符串，可为空） | `$done({title, content})`，展示给用户 |
| `dns`（M7） | `[Host]` 中 `server:script:<名称>` | `$domain` | `$done({addresses, ttl})` |
| `rule`（M7） | `SCRIPT,<名称>,策略` 规则 | 与路由上下文对应的对象 | `$done({matched})` |

cron：最小间隔 1 分钟；上一次未结束时跳过本次；错过的触发不补跑。

## 3. 运行时设计

### 3.1 接口

```swift
public protocol ScriptRuntime: Sendable {
    func run(_ invocation: ScriptInvocation) async -> ScriptOutcome
    func releaseIdleResources() async          // 内存压力或空闲时调用
    func shutdown() async
}

public struct ScriptInvocation: Sendable {
    public let script: ScriptDescriptor        // 名称、类型、源码（已加载）、argument、timeout、binaryBodyMode
    public let payload: ScriptPayload          // .httpRequest / .httpResponse / .cron / .event / .generic / .evaluate（调试）
    public let environment: ScriptEnvironment  // 版本、语言、设备型号、网络快照
}

public struct ScriptOutcome: Sendable {
    public enum Result: Sendable { case done(ScriptValue?), timedOut, exception(message: String, line: Int?), aborted }
    public let result: Result
    public let logs: [String]                  // console 输出，最多 100 条
    public let duration: Duration
}

/// 宿主提供的能力。隧道注入基于引擎的实现；App 的脚本调试注入基于 URLSession 的实现。
public protocol ScriptHostServices: Sendable {
    func httpRequest(_ request: ScriptHTTPRequest) async throws -> ScriptHTTPResponse   // $httpClient
    func storeRead(key: String) -> String?                                               // $persistentStore
    func storeWrite(key: String, value: String?) -> Bool
    func postNotification(_ notification: ScriptNotification) async                     // $notification
    func geoip(_ ip: String) -> String?                                                  // $utils
    func asn(_ ip: String) -> (number: String, organization: String?)?
}
```

运行时构造时接收 `ScriptHostServices`；运行时本身不直接访问网络、文件或数据库。

### 3.2 执行模型

- **工作线程**：每个工作线程持有一个 `JSVirtualMachine`，只在该线程上使用。默认 1 个工作线程，内存余量充足时最多 2 个。
- **每次执行一个新的 `JSContext`**：全局状态不跨执行泄漏；同一 VM 内的上下文创建成本低。字节码缓存属于可选优化：只有确认 SDK 公开头文件提供相应 API（如 `JSScript`）时才使用，否则每次直接求值源码。
- **队列**：等待执行的调用最多 32 个；队满时跳过本次脚本（请求照常继续），备注 `SCR-003`。
- **完成**：`$done` 第一次调用生效，之后的调用忽略并记日志。
- **超时**：`timeout` 到期仍未 `$done` → 结果为 `timedOut`；该上下文的所有挂起操作（`$httpClient` 回调、定时器）通过"代次号"作废，回调到达时直接丢弃。
- **释放**：执行结束释放上下文；工作线程空闲 5 秒调用 `JSGarbageCollect`；空闲 60 秒释放 VM，下次惰性重建。

### 3.3 同步死循环

JavaScriptCore 的公开 API 不能中断正在同步执行的脚本（ADR-010）。处理方式：

1. 看门狗：工作线程在 `timeout + 2 秒` 内没有从求值中返回，标记为"失效"，不再分配任务；新建一个工作线程接替。失效线程无法回收，只能等隧道重启。
2. 导致失效的脚本被自动停用，直到用户修改或手动重新启用；写日志簿并在首页提示（`SCR-007`）。
3. 失效线程累计达到 2 个时，本次隧道运行期间停用全部脚本（`SCR-008`），首页提示重启隧道。

### 3.4 内存

- 脚本运行时预算 ≤ 6 MiB（[02 §6](02-architecture.md#6-内存预算)），只在活动时占用。
- 内存压力 warning：立即释放空闲 VM；critical：新的脚本调用直接跳过（请求照常继续），备注 `SCR-008`。
- 传入的 Body 在调用前已受 `max-size` 限制；`$httpClient` 响应体上限 4 MiB。

### 3.5 数据传递

- 文本 Body 以 JS 字符串传入（按 `charset` 或 UTF-8 解码，非法序列用替换字符）；`binary-body-mode = true` 时以 `Uint8Array` 传入（用 `JSObjectMakeTypedArrayWithBytesNoCopy` 避免拷贝）。
- 返回值从 `JSValue` 转换为 `ScriptValue`（JSON 兼容的递归枚举 + `bytes`），类型不符时报 `SCR-006` 并按"不修改"处理。

## 4. 全局 API

| API | 签名 / 结构 | 说明 |
| --- | --- | --- |
| `$done` | `$done(value?)` | 结束执行；必须调用，否则超时 |
| `$argument` | `string` | 配置中的 `argument`，未设置时为空字符串 |
| `$script` | `{name, type, startTime}` | `startTime` 为 `Date` |
| `$environment` | `{system: "iOS", "aether-version", "aether-build", language, "device-model"}` | |
| `$network` | `{"interface-type": "wifi"\|"cellular"\|"wired"\|"none", wifi: {ssid, bssid} \| null}` | SSID 不可得时为 `null` |
| `$persistentStore.write` | `(value: string \| null, key?: string) → boolean` | 省略 `key` 时使用脚本名作为键；`value` 为 `null` 删除该键 |
| `$persistentStore.read` | `(key?: string) → string \| null` | |
| `$httpClient.get` 等 | `(urlOrOptions, callback(error, response, data))` | 方法：`get`、`post`、`put`、`delete`、`head`、`options`、`patch`，见 §6 |
| `$notification.post` | `(title, subtitle, body, options?)` | 见 §7 |
| `$utils.geoip` | `(ip: string) → string \| null` | 国家代码；数据库未加载时为 `null` |
| `$utils.ipasn` / `$utils.ipaso` | `(ip: string) → string \| null` | ASN 号 / 组织名 |
| `$utils.ungzip` | `(data: Uint8Array) → Uint8Array` | 解压后上限 8 MiB |
| `console.log` / `info` / `warn` / `error` / `debug` | `(...args)` | 写入脚本日志；`debug = true` 时同时写入请求备注 |
| `setTimeout` / `clearTimeout` | 浏览器语义 | 同一执行内最多 64 个定时器；不能超过脚本剩余时间 |
| `setInterval` / `clearInterval` | 浏览器语义 | 同上 |
| `atob` / `btoa`、`TextEncoder` / `TextDecoder`（UTF-8）、`URLSearchParams` | 标准语义 | 由 Aether 自带的预置脚本提供（JavaScriptCore 本身没有这些 Web API） |
| `$intent.parameter` | `string` | 仅 `generic` |
| `$event` | `{name, data}` | 仅 `event` |
| `$httpAPI`（M7） | `(method, path, body, callback(result))` | 调用控制接口（[10 §6](10-control-ipc.md#6-http-控制接口m7)） |

预置脚本是 Aether 仓库中的 JS 源文件，在每个上下文创建后最先执行；它只能定义上表中的 API，不得引入第三方代码。

## 5. HTTP 脚本

### 5.1 对象

```text
$request  = { url: string, method: string, headers: object, body?: string | Uint8Array, id: string }
$response = { status: number, headers: object, body?: string | Uint8Array }
```

- `body` 只在 `requires-body = true` 且 Body 非空时存在。
- `id` 在同一请求的 http-request 与 http-response 脚本间相同。
- `headers`：
  - 读取时**不区分大小写**（以 JS Proxy 实现），遍历时返回原始大小写；
  - 同名多值以 `, ` 合并为一个字符串；脚本返回的头中某个值与合并结果完全相同时，写回原始的多个头（避免破坏多个 `Set-Cookie`）。

### 5.2 http-request 的 `$done`

| 调用 | 效果 |
| --- | --- |
| `$done()` 或 `$done({})` | 请求不变，继续 |
| `$done({url})` | 替换 URL（不自动改 `Host`；需要时一并返回 `headers`） |
| `$done({headers})` | 替换全部请求头 |
| `$done({body})` | 替换 Body（仅 `requires-body = true` 时有效）；Aether 自动修正 `Content-Length` |
| `$done({response: {status?, headers?, body?}})` | 不连接上游，直接返回该响应（`status` 默认 200） |
| `$done({abort: true})` | 中止请求并关闭连接 |

`url` 改为不同主机时，按新主机重新路由（与 URL 重写的 `header` 类相同）。

### 5.3 http-response 的 `$done`

| 调用 | 效果 |
| --- | --- |
| `$done()` 或 `$done({})` | 响应不变 |
| `$done({status?, headers?, body?})` | 替换对应部分；Body 被替换时自动修正 `Content-Length` 并移除 `Content-Encoding` |
| `$done({abort: true})` | 关闭连接，不向客户端返回响应 |

### 5.4 执行顺序

同一 URL 命中多个脚本时，按配置顺序（模块脚本在前）依次执行，后一个看到前一个的修改。与重写的相对顺序见 [08 §5](08-mitm-rewrite.md#5-http-处理管线)。

## 6. `$httpClient`

| 选项 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `url` | string | 必需 | |
| `headers` | object | `{}` | |
| `body` | string / object / Uint8Array | 空 | object 序列化为 JSON 并设置 `Content-Type: application/json` |
| `timeout` | 秒 | 5 | 不超过脚本剩余时间 |
| `insecure` | bool | `false` | 不验证 TLS 证书 |
| `auto-redirect` | bool | `true` | 最多跟随 5 次 |
| `policy` | 策略名 | 按规则 | 指定出站策略 |
| `binary-mode` | bool | `false` | `data` 以 `Uint8Array` 返回 |

- 回调参数：`error` 为字符串或 `null`；`response` 为 `{status, headers}`；`data` 为字符串或 `Uint8Array`。
- 请求由引擎发出，按规则（或 `policy`）选择出站；**不经过** HTTP 管线（不触发重写、MitM 与其它脚本，避免递归）。
- 在请求列表中以入站类型"脚本：<脚本名>"显示。
- 每次执行内并发请求最多 8 个；响应体上限 4 MiB。

## 7. `$notification`

- 隧道通过 `UNUserNotificationCenter` 发送本地通知；首次使用前 App 需要已获得通知权限（App 在用户启用含通知的脚本时请求）。🔬 验证隧道扩展内发送本地通知。
- `options`：`url`（或兼容写法 `open-url`，点击后由 App 打开该 URL）、`sound`（bool，默认 `false`）。`media-url` 在 M7。
- 频率限制：每个脚本每分钟最多 5 条，超出丢弃并记日志（`SCR-009`）。

## 8. `$persistentStore`

- 存储在数据库表 `script_store` 中（[11 §4](11-storage.md#4-数据库)），按键全局共享——这与主流客户端一致，跨脚本共享数据的写法依赖这一点。
- 值为字符串，单个值 ≤ 1 MiB，总量 ≤ 16 MiB；超限时 `write` 返回 `false`。
- 读写在调用线程同步完成（隧道内有内存缓存，后台批量落盘）。
- App 的"脚本存储"页面可查看、编辑、删除键值。

## 9. 获取与更新

- `script-path` 为 URL 时作为外部资源下载与缓存（[11 §5](11-storage.md#5-外部资源)），按 `script-update-interval` 更新；本地路径相对于 `Scripts/`。
- 源码不可用（从未下载成功）时跳过该脚本，备注 `SCR-005`。
- `debug = true` 时每次执行前重新读取文件。

## 10. 调试

App 的脚本编辑器（M6）：

- JavaScript 语法高亮编辑；
- "运行"：选择模拟类型（http-request / http-response / generic / cron），编辑模拟请求（URL、方法、头、Body）与模拟响应，填写 `argument`；
- 隧道运行时通过 IPC `evaluateScript` 在隧道内执行（与真实环境一致）；隧道未运行时在 App 进程内用同一个 `AetherScript` 执行；
- 输出：`$done` 的值（格式化 JSON）、console 日志、异常（含行号）、耗时。

## 11. 错误码

| 码 | 含义 |
| --- | --- |
| `SCR-001` | 执行超时 |
| `SCR-002` | 脚本抛出异常 |
| `SCR-003` | 执行队列已满，跳过 |
| `SCR-004` | Body 超过 `max-size`，跳过 |
| `SCR-005` | 脚本源码不可用 |
| `SCR-006` | `$done` 的值无效 |
| `SCR-007` | 工作线程失效（疑似同步死循环），脚本已停用 |
| `SCR-008` | 脚本功能暂时停用（内存压力或失效线程过多） |
| `SCR-009` | 通知频率超限 |

## 12. 测试要求

| 测试 | 内容 |
| --- | --- |
| API 单元 | 每个全局 API 的正常与边界行为 |
| `$done` 语义 | §5.2、§5.3 表中的每一行 |
| 超时与作废 | 超时后到达的 `$httpClient` 回调与定时器被丢弃，不影响后续执行 |
| 死循环 | `while(true){}` 触发看门狗与停用逻辑，其它脚本继续工作 |
| 二进制 | `binary-body-mode` 往返，不发生拷贝之外的数据损坏 |
| 头部 | 大小写不敏感读取、多值合并与写回 |
| 兼容套件 | `Tests/Fixtures/scripts/compat/` 中由项目自行编写的脚本，覆盖常见写法：环境检测、Promise 包装 `$httpClient`、`async/await`、JSON Body 改写、`$persistentStore` 计数、通知 |

脚本测试在 macOS 主机上运行（JavaScriptCore 可用），CI 的 `ios.yml` 中执行。
