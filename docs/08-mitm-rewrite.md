# 08 MitM、重写与抓包

`AetherHTTP` 负责所有"看得见 HTTP 内容"的处理：为用户授权的主机终止 TLS、执行重写与脚本、记录抓包。配置语法见 [04 §9–§11](04-profile-spec.md#9-重写类节m5)。里程碑：M5（HTTP/2 在 M7）。

## 1. 什么时候"看得见"

| 流 | HTTP 可见 | 说明 |
| --- | --- | --- |
| HTTP 代理入站的绝对形式请求 | ✓ | 明文 |
| TUN 上嗅探到的明文 HTTP | ✓ | 仅当重写、脚本、抓包任一开启时进入管线，否则原始转发 |
| HTTPS，主机命中 `[MITM] hostname`，MitM 开关打开，CA 可用 | ✓ | TLS 终止 |
| 其它 HTTPS / TLS | ✗ | 只有主机名、端口、字节数 |

## 2. 证书体系

### 2.1 根证书（CA）

在 App 中生成。证书相关逻辑（CA 生成、叶子签发、`.mobileconfig`、备份格式）都在跨平台模块 `AetherCertificates` 中，App 与 `AetherHTTP` 共用：

| 字段 | 值 |
| --- | --- |
| 密钥 | ECDSA P-256 |
| 主题 | `CN=Aether CA <生成日期> <4 位随机十六进制>`，`O=Aether` |
| 序列号 | 16 字节随机正整数 |
| 有效期 | 生成前 1 天起，5 年 |
| 扩展 | BasicConstraints `CA:TRUE, pathLen:0`（critical）；KeyUsage `keyCertSign, cRLSign`（critical）；SubjectKeyIdentifier |
| 签名 | ECDSA-SHA256 |

### 2.2 存储

- Keychain 通用密码项，服务名 `aether.mitm.ca`，共享访问组，`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`，不同步到 iCloud。
- 内容：JSON `{version, privateKeyPKCS8 (Base64), certificateDER (Base64), createdAt}`。
- 隧道启动时读取一次；App 重新生成或导入 CA 后，通过 IPC 通知隧道重新加载。

### 2.3 安装引导

1. App 生成 `.mobileconfig`（`PayloadType = com.apple.security.root`，`PayloadContent` 为证书 DER，`PayloadIdentifier = <Bundle ID 前缀>.ca.<序列号前 8 位>`，随机 `PayloadUUID`，显示名 "Aether CA"）。
2. App 在 `127.0.0.1` 随机端口启动一个临时 HTTP 服务（只提供这一个文件），申请后台任务保活，用 Safari 打开 `http://127.0.0.1:<端口>/aether-ca.mobileconfig`；文件被下载一次或 120 秒后关闭服务。
3. 页面引导：设置 → 通用 → VPN 与设备管理 → 安装描述文件；再到 设置 → 通用 → 关于本机 → 证书信任设置 中打开完全信任。
4. 备选：通过分享面板把 `.mobileconfig` 存到"文件"，在"文件"中点开安装。

🔬 两条路径都要真机验证（尤其是 App 切到后台后临时服务是否仍可访问）。

### 2.4 信任检测

App 在前台、以及从设置返回时检测：用 CA 签发一张主机名为 `trust-check.aether.invalid` 的叶子证书，以 `SecPolicyCreateSSL(true, 该主机名)` 和链 `[叶子, CA]`（不设置自定义锚点）调用 `SecTrustEvaluateWithError`。通过即表示用户已安装并完全信任该 CA。

| 状态 | 显示 |
| --- | --- |
| 未生成 | "生成证书"按钮 |
| 已生成，未信任 | "安装与信任"引导（无法区分"未安装"与"已安装未信任"，两步说明都显示） |
| 已信任 | 绿色状态；证书主题、到期时间 |

MitM 开关打开但 CA 未信任时，首页显示警告；隧道仍按配置解密（因为信任状态只能在 App 中检测），客户端会报证书错误。

### 2.5 重新生成、导入与导出

- **重新生成**：二次确认，提示旧证书将失效、应在设置中删除旧描述文件。
- **导入**：支持 PKCS#12（`.p12`，以及配置中的 `ca-p12` + `ca-passphrase`），在 App 中用 Security 框架的 `SecPKCS12Import` 解析后转存为 §2.2 的格式；支持 ECDSA P-256 与 RSA（≥ 2048 位）密钥。也支持导入 Aether 自己的备份格式。
- **导出（含私钥）**：Aether 备份格式——JSON 内容以 AES-256-GCM 加密，密钥由用户口令经 PBKDF2-SHA256（60 万次迭代，随机 salt）派生；文件扩展名 `.aetherca`。导出前二次确认并提示风险。
- **导出（仅证书）**：DER / PEM / `.mobileconfig`，无需确认。

### 2.6 叶子证书

| 字段 | 值 |
| --- | --- |
| 密钥 | 每次隧道启动生成一把 P-256 密钥，所有叶子证书共用 |
| 主题 | `CN=<主机名>` |
| SAN | DNS：主机名（精确主机名，不签通配证书）；主机为 IP 时为 IP SAN |
| EKU | serverAuth |
| KeyUsage | digitalSignature（CA 为 RSA 时另加 keyEncipherment） |
| 有效期 | 生成前 1 天起，365 天（满足系统对 TLS 服务器证书有效期的要求） |
| 签名 | 由 CA 签名：P-256 CA 用 ECDSA-SHA256；RSA CA 用 RSA-SHA256 |
| 缓存 | 按主机名 LRU 64 条；签发在 NIO 线程池中执行，命中缓存时同步返回 |

## 3. 解密判定

- `hostname` 模式匹配：先看排除项（`-` 前缀），再看包含项；端口默认 443，`host:port` 指定其它端口。
- **证书固定自动跳过**：同一主机 60 秒内 3 次出现"客户端在我方证书后中止握手"（收到 `bad_certificate`、`unknown_ca`、`certificate_unknown` 告警，或 ServerHello 后立即断开），则该主机进入临时跳过表 30 分钟，期间原始转发；请求记录备注"疑似证书固定，已临时跳过解密"，并写日志簿。
- `auto-quic-block = true` 时，发往 MitM 主机 UDP 443 的流被拒绝，迫使客户端回退到 TCP。

## 4. TLS 终止

1. 在客户端 Channel 上加入 swift-nio `NIOTLS` 模块的 `SNIHandler` 读取 ClientHello；证书主机名 = SNI，没有 SNI 时用流的主机名。
2. 取得叶子证书（缓存或签发）；`NIOSSLContext` 按主机名缓存（LRU 64），证书链为 `[叶子, CA]`，ALPN 只提供 `http/1.1`（M7 起 `h2 = true` 时提供 `h2, http/1.1`）。
3. 握手完成后加入 HTTP/1.1 服务端编解码器与 `HTTPServerPipelineHandler`。
4. **上游连接延迟到第一个请求**：这样 URL 重写、Map Local 和"直接返回响应"的脚本无需连接上游；并且可以用完整的 URL 与 User-Agent 重新做一次规则匹配（`URL-REGEX`、`USER-AGENT` 在 MitM 流上因此能生效）。上游连接池以 `(策略, 主机, 端口)` 为键，keep-alive 空闲 60 秒。
5. 上游 TLS：SNI = 主机名；`skip-server-cert-verify = false` 时完整验证。验证失败 → 向客户端返回 `502` 与说明页，请求记录 `MITM-004`。
6. `Upgrade: websocket` 等升级请求：收到 `101` 后两侧切换为原始转发，不再解析帧。

## 5. HTTP 处理管线

明文 HTTP 与 TLS 终止后的 HTTPS 共用同一条管线。每个请求-响应对是一个 `HTTPExchange`。

**请求阶段**

1. 开始抓包记录（若开启）。
2. 规则重新匹配（URL、User-Agent 可见），确定本请求的出站策略。
3. `[URL Rewrite]`：第一条命中者生效。重定向与拒绝类直接构造响应；`header` 类改写 URL 与 `Host`，并回到第 2 步对新主机重新匹配（最多 3 次，防止循环）。
4. `[Map Local]`：命中则直接构造响应。
5. `[Header Rewrite]`（`http-request`）：所有命中项依次执行。
6. 需要请求 Body 时（命中请求 Body 重写，或命中 `requires-body = true` 的 http-request 脚本），按 §6 缓冲并解压。
7. `[Body Rewrite]`（`http-request`）：依次执行。
8. `http-request` 脚本：按顺序依次执行，后者看到前者的修改；脚本可返回响应（跳过上游）或中止（关闭连接）。
9. 发送到上游。

**响应阶段**

10. `[Header Rewrite]`（`http-response`）。
11. 需要响应 Body 时缓冲并解压。
12. `[Body Rewrite]`（`http-response`）。
13. `http-response` 脚本：依次执行。
14. 发送给客户端；完成抓包记录；更新请求记录（方法、URL、状态码、备注）。

每一步如有效果（命中重写、脚本修改、跳过原因），都向请求记录写一条备注。

## 6. Body 处理

- **默认流式**：没有任何步骤需要完整 Body 时，Body 不缓冲，边收边发；抓包开启时旁路复制前 1 MiB。
- **缓冲上限**：取命中脚本的 `max-size` 与 Body 重写上限（1 MiB）中的较大值；`Content-Length` 超限时直接跳过需要 Body 的步骤；无长度的分块传输在缓冲到上限时停止缓冲，已缓冲部分原样发出，其余流式转发，并备注"超出大小，跳过处理"。全局缓冲总量上限见 [06 §13](06-network-engine.md#13-资源控制与背压)。
- **解压**：`gzip`、`deflate`（zlib）；`br` 在 Apple 平台用 Compression 框架解码，其它平台跳过处理；`zstd` 跳过处理并备注 `MITM-011`。解压后大小上限为 8 MiB 与 `4 × 上限` 中的较小者，防止压缩炸弹。
- **重新编码**：Body 被修改后以未压缩形式发送，移除 `Content-Encoding` 与 `Transfer-Encoding: chunked`，设置正确的 `Content-Length`。Body 未被修改时发送原始（压缩）字节。
- **文本判断**：Body 重写只处理 `Content-Type` 为 `text/*`、`application/json`、`application/javascript`、`application/xml`、`application/x-www-form-urlencoded` 或带 `+json` / `+xml` 后缀的内容，且能按 UTF-8（或 `charset` 声明的编码）解码。

## 7. 重写细节

- 正则在完整 URL 上做搜索（非整串匹配），区分大小写；URL 重写只替换第一个匹配部分（[04 §9.1](04-profile-spec.md#91-url-rewrite)）；替换中的 `$0`…`$9` 引用分组，`$$` 表示字面 `$`。
- `302` / `307` 响应体为空，带 `Location` 与 `Content-Length: 0`。
- `reject-img` 返回 43 字节的 1×1 透明 GIF，`Content-Type: image/gif`。
- `header` 类改写到不同 scheme（如 http → https）时，上游按新 scheme 连接。
- Header Rewrite 中 `header-replace` 对多个同名头：删除全部后写入一个新值。
- Map Local 的 `data-type=file` 引用 URL 时作为外部资源下载缓存（[11 §5](11-storage.md#5-外部资源)），未缓存时返回 `502` 并备注。

## 8. 抓包

| 项 | 规则 |
| --- | --- |
| 开关 | 功能开关"抓包"，运行时可切换；只对 HTTP 可见的请求记录内容 |
| 内容 | 请求行、请求头、响应状态、响应头、各阶段时间；请求与响应 Body 各前 1 MiB（存原始字节并记录编码，展示时解压） |
| 存储 | App Group `Capture/` 目录，每个 exchange 两个文件；总量上限 64 MiB（可在设置中调整为 16–256 MiB），超限按最旧删除 |
| 清除 | 设置中"清除抓包数据"；配置切换不清除 |
| 导出 | HAR 1.2（单个或当前筛选结果）、cURL 命令、原始文本 |
| 敏感头 | `Authorization`、`Proxy-Authorization`、`Cookie`、`Set-Cookie` 在导出时默认替换为 `******`，导出面板提供"包含敏感信息"开关 |

非 HTTP 可见的流只有请求记录中的元数据，没有内容。

## 9. 隐私与安全

- MitM 只作用于用户显式列出的主机；`hostname = *` 会在首页持续提示。
- CA 私钥不离开 Keychain，除非用户显式导出备份。
- 抓包数据只在设备上，导出需要用户操作。
- 日志中不记录 Body 与敏感头的值（[02 §8.2](02-architecture.md#82-日志)）。

## 10. 错误码

| 码 | 含义 |
| --- | --- |
| `MITM-001` | 未生成 CA |
| `MITM-002` | CA 未被信任（App 检测结果） |
| `MITM-003` | 客户端拒绝了 Aether 签发的证书（疑似证书固定） |
| `MITM-004` | 上游服务器证书验证失败 |
| `MITM-005` | 叶子证书签发失败 |
| `MITM-010` | Body 超过上限，跳过处理 |
| `MITM-011` | 不支持的内容编码，跳过处理 |
| `MITM-012` | HTTP 报文解析失败 |

## 11. 测试要求

| 测试 | 内容 |
| --- | --- |
| 证书 | 生成的 CA 与叶子证书用 swift-certificates 解析并校验扩展；在 macOS 上用 Security 框架以 CA 为锚点验证叶子链 |
| TLS 终止 | 本地客户端（信任测试 CA）经 MitM 访问本地 HTTPS 源站，内容一致 |
| 管线顺序 | 同一请求同时命中 URL 重写、Header 重写、Body 重写与脚本时，各步按 §5 顺序生效（以备注顺序断言） |
| Body | Content-Length、分块、gzip、超限、非文本、解压炸弹 |
| 证书固定跳过 | 模拟客户端以 `unknown_ca` 中止握手 3 次后进入跳过表 |
| 上游证书 | 自签名源站在 `skip-server-cert-verify` 两种取值下的行为 |
| 抓包 | 总量上限与淘汰；HAR 输出通过 HAR 1.2 schema 校验 |
