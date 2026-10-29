# 04 配置文件规范

本章定义 Aether 配置（`.conf`）与模块（`.amodule`）的语法和语义，是 `AetherProfile` 的实现依据。语法与业界主流同类客户端通用的 INI 风格兼容；Aether 自有的扩展键在表中标注 **[ext]**。

每个键与类型都标注引入的里程碑（M1–M7）。解析器从 M1 起就要**识别**全部列出的语法；尚未实现的能力解析后给出 `CFG-022` / `CFG-031` 等诊断，而不是报语法错误。

完整示例见 [`examples/full.conf`](../examples/full.conf)。

## 1. 文件类型

| 扩展名 | 含义 | 说明 |
| --- | --- | --- |
| `.conf` | 配置 | 一个完整的行为定义 |
| `.amodule` | Aether 模块 | 叠加在配置上的片段，见 §12 |
| `.sgmodule` | 兼容模块 | 语法与 `.amodule` 相同，按 `.amodule` 处理 |
| `.yaml` / `.yml` | 外部格式 | 仅用于导入（节点订阅或整份配置转换），见 §12.4 |
| `.list` / `.txt` | 规则集 / 域名集 | 见 [05 §6](05-rule-engine.md#6-规则集与域名集) |

## 2. 词法

- 编码 UTF-8，可带 BOM（解析时去除，渲染时保留原样）。换行 LF 或 CRLF，渲染时保留原换行风格。
- 每一行是以下之一：空行、注释、指令、节标题、条目。
- **注释**：去掉行首空白后以 `#`、`;` 或 `//` 开头的行。**不支持行尾注释**（值中可能合法出现 `#`）。
- **指令**：以 `#!` 开头的行。文件开头的指令是元数据（如 `#!MANAGED-CONFIG`、模块的 `#!name=`）；其它位置的指令保留原样并给出 `CFG-003`。
- **节标题**：`[名称]`。匹配节名时不区分大小写、忽略首尾空白，但渲染时保留原拼写。第一个节标题之前的条目给出 `CFG-004`。
- **条目**：节内的非空非注释行，具体格式由所在节决定（见各节）。
- 同名节出现多次时，按出现顺序合并为一个逻辑节。

## 3. 值语法

### 3.1 字段列表

多数条目的值是逗号分隔的字段列表：

```text
字段 := 裸字段 | 引号字段
裸字段 := 不含逗号、不以引号开头的字符序列（首尾空白被去除）
引号字段 := '"' (除 '"' 与 '\' 外的任意字符 | '\"' | '\\')* '"'
```

- 引号字段用于包含逗号、首尾空白的值，例如 `ws-headers="Host:a.com|User-Agent:x, y"`。
- `key=value` 形式的字段：第一个 `=` 前是键（去空白、不区分大小写），之后是值；值本身也可以是引号字段。
- 规则行中的括号嵌套见 §7.3。

### 3.2 基本类型

| 类型 | 写法 | 说明 |
| --- | --- | --- |
| bool | `true` / `false`（也接受 `1` / `0`、`yes` / `no`、`on` / `off`） | 渲染时保留原写法 |
| int | 十进制整数 | 超出范围为 `CFG-020` |
| 秒 | 整数或小数，单位秒 | 如 `timeout=5`、`timeout=0.5` |
| 毫秒 | 整数 | 仅 `tolerance` 使用 |
| 字节 | 整数，单位字节 | 如 `max-size=131072` |
| 列表 | 逗号分隔的字段 | `[General]` 中的列表值 |
| 正则 | ICU 语法（`NSRegularExpression`） | 两个平台均可用 |
| 通配 | `*` 匹配任意个任意字符（含 `.`），`?` 匹配一个字符 | 不区分大小写 |
| URL | `http://`、`https://` 或本地相对路径 | 本地路径相对于配置文件所在目录（App Group 的 `Profiles/`） |

## 4. [General]

格式：`键 = 值`，第一个 `=` 分隔。

| 键 | 类型 | 默认值 | 里程碑 | 说明 |
| --- | --- | --- | --- | --- |
| `loglevel` | `debug` / `info` / `notice` / `warning` / `error` | `notice` | M1 | 别名：`verbose`→`debug`，`notify`→`notice` |
| `dns-server` | 列表：`system` 或 `IP[:端口]` | `system` | M2 | 普通 UDP DNS 上游 |
| `encrypted-dns-server` | 列表：`https://…`、`tls://host[:端口]`、`quic://…`（M7） | 空 | M3 | 设置后**替代** `dns-server` 用于普通查询；`dns-server` 仍用于解析加密 DNS 服务器自身的域名 |
| `encrypted-dns-skip-cert-verify` | bool | `false` | M3 | |
| `dns-mode` **[ext]** | `fake-ip` / `real-ip` | `fake-ip` | M2 | 见 [07](07-dns.md) |
| `fake-ip-range` **[ext]** | IPv4 CIDR | `198.18.0.0/15` | M2 | |
| `always-real-ip` | 域名通配列表 | 内置默认表 | M2 | 这些域名返回真实 IP，内置表见 [07 §3.3](07-dns.md#33-真实-ip-例外) |
| `hijack-dns` | 列表：`IP:端口` 或 `*:53` | `*:53` | M2 | 发往这些地址的 DNS 查询由 Aether 应答 |
| `ipv6` | bool | `false` | M2 / M7 | `false`：AAAA 返回空；`true` 的支持在 M7 |
| `skip-proxy` | 列表：CIDR 或域名通配 | 见下 | M2 | 写入系统代理例外，CIDR 同时加入 TUN 排除路由 |
| `exclude-simple-hostnames` | bool | `true` | M2 | 不含点的主机名不走系统代理 |
| `system-proxy` **[ext]** | bool | `true` | M2 | 是否设置系统 HTTP 代理入口，见 [06 §5.2](06-network-engine.md#52-http-代理入站) |
| `tun-included-routes` | CIDR 列表 | 空（=默认路由） | M2 | |
| `tun-excluded-routes` | CIDR 列表 | 空 | M2 | 与内置排除表合并 |
| `tun-mtu` **[ext]** | int（1280–9000） | `1500` | M2 | |
| `sniffing` **[ext]** | bool | `true` | M2 | 对目标为 IP 的连接嗅探 TLS SNI / HTTP Host |
| `block-quic` | `auto` / `always` / `never` | `auto` | M2 | `auto`：目标策略不支持 UDP 或主机命中 MitM 时拒绝 UDP 443 |
| `udp-policy-not-supported-behaviour` | `DIRECT` / `REJECT` | `REJECT` | M2 | UDP 流命中不支持 UDP 的策略时的处理 |
| `internet-test-url` | URL | `http://www.apple.com/library/test/success.html` | M3 | DIRECT 连通性测试 |
| `proxy-test-url` | URL | `http://www.gstatic.com/generate_204` | M3 | 节点测速默认地址 |
| `test-timeout` | 秒 | `5` | M3 | |
| `geoip-db-url` **[ext]** | URL | 空 | M3 | MMDB 格式国家库；别名 `geoip-maxmind-url` |
| `ipasn-db-url` **[ext]** | URL | 空 | M3 | MMDB 格式 ASN 库 |
| `resource-update-interval` **[ext]** | 秒 | `86400` | M3 | 未单独指定间隔的外部资源默认更新间隔 |
| `resource-fetch-policy` **[ext]** | 策略名 | `DIRECT` | M3 | 隧道下载外部资源时使用的出站策略 |
| `show-error-page-for-reject` | bool | `false` | M5 | 明文 HTTP / MitM 请求被拒绝时返回说明页 |
| `http-api` | `密钥@地址:端口` | 空 | M7 | 如 `mykey@127.0.0.1:6170` |
| `http-api-tls` | bool | `false` | M7 | |
| `allow-wifi-access` | bool | `false` | M7 | 局域网共享 |
| `wifi-access-http-port` | int | `6171` | M7 | |
| `wifi-access-socks5-port` | int | `6172` | M7 | |

`skip-proxy` 默认值：`127.0.0.0/8, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16, localhost, *.local`。

列表值只出现一次时整体替换默认值；需要在默认值基础上增补时，用模块的 `%APPEND%`（§12.2）。

## 5. [Proxy]

格式：`名称 = 类型, 字段…`。名称是 `=` 左侧去首尾空白后的全部字符（可含空格、emoji），在 `[Proxy]` 与 `[Proxy Group]` 之间全局唯一，且不得与内置策略名（不区分大小写）冲突。

### 5.1 内置策略与别名

内置策略可在任何引用策略的地方直接使用，无需定义：

| 名称 | 行为 |
| --- | --- |
| `DIRECT` | 直连 |
| `REJECT` | TCP：明文 HTTP / MitM 请求返回错误（或说明页），其它连接立即关闭；UDP：丢弃 |
| `REJECT-DROP` | 静默丢弃，不关闭连接（对端最终超时），用于对付会立即重试的客户端 |
| `REJECT-NO-DROP` | 与 `REJECT` 相同，但不参与"短时间内大量拒绝自动升级为 DROP"的保护（见 [06 §8.3](06-network-engine.md#83-拒绝策略)） |
| `REJECT-TINYGIF` | 明文 HTTP / MitM 请求返回 1×1 透明 GIF；其它连接同 `REJECT` |

也可以在 `[Proxy]` 中用类型 `direct`、`reject`、`reject-drop`、`reject-no-drop`、`reject-tinygif` 定义带名字的别名，例如 `国内直连 = direct`。

### 5.2 通用参数

| 参数 | 类型 | 默认 | 里程碑 | 说明 |
| --- | --- | --- | --- | --- |
| `udp-relay` | bool | `false` | M2 | 是否通过该节点转发 UDP |
| `test-url` | URL | `proxy-test-url` | M3 | |
| `test-timeout` | 秒 | `test-timeout` | M3 | |
| `ip-version` | `dual` / `v4-only` / `v6-only` / `prefer-v4` / `prefer-v6` | `dual` | M3 | 解析服务器地址时的地址族策略，`dual` 使用 Happy Eyeballs |
| `block-quic` | `auto` / `on` / `off` | `auto` | M2 | 覆盖全局 `block-quic` |
| `underlying-proxy` | 策略名 | 空 | M7 | 经由另一个策略连接到本节点服务器（代理链） |
| `tfo` | bool | — | — | 解析后忽略，给出 `CFG-024` |

### 5.3 TLS 参数

适用于 `https`、`socks5-tls`、`trojan`，以及开启 `tls=true` 的 `vmess` / `vless`。

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `sni` | 字符串或 `off` | 服务器域名 | `off` 不发送 SNI |
| `skip-cert-verify` | bool | `false` | 跳过服务端证书验证；节点详情页显示警告 |
| `server-cert-fingerprint-sha256` | 64 位十六进制（可含 `:`） | 空 | 证书指纹固定；设置后只校验指纹 |
| `alpn` | 引号内逗号分隔 | 协议默认 | 如 `alpn="h2,http/1.1"` |

### 5.4 WebSocket 参数

适用于 `trojan`、`vmess`、`vless`。

| 参数 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `ws` | bool | `false` | |
| `ws-path` | 字符串 | `/` | |
| `ws-headers` | `名:值` 以 `\|` 分隔 | 空 | 如 `ws-headers="Host:cdn.example.com"` |

### 5.5 各类型

位置字段之后为 `key=value` 参数。"必需"列为缺失时报 `CFG-021` 的参数。

| 类型 | 位置字段 | 必需 | 其它参数 | 里程碑 |
| --- | --- | --- | --- | --- |
| `http` | `服务器, 端口[, 用户名, 密码]` | — | `username`、`password`、`always-use-connect`（bool，默认 `false`：明文请求走普通代理转发） | M2 |
| `https` | 同 `http` | — | 同 `http` + TLS | M2 |
| `socks5` | `服务器, 端口[, 用户名, 密码]` | — | `username`、`password`、`udp-relay` | M2 |
| `socks5-tls` | 同 `socks5` | — | 同 `socks5` + TLS | M2 |
| `ss` | `服务器, 端口` | `encrypt-method`、`password` | `obfs`（`http` / `tls`）、`obfs-host`、`obfs-uri`、`udp-relay` | M3 |
| `trojan` | `服务器, 端口` | `password` | TLS、WebSocket、`udp-relay` | M3 |
| `vmess` | `服务器, 端口` | `username`（UUID） | `encrypt-method`（`auto` / `aes-128-gcm` / `chacha20-poly1305` / `none`，默认 `auto`）、`vmess-aead`（必须为 `true`，默认 `true`）、`tls`、TLS、WebSocket、`udp-relay` | M3 |
| `vless` **[ext]** | `服务器, 端口` | `username`（UUID） | `tls`、TLS、WebSocket、`flow`（仅支持空）、`udp-relay` | M3 |
| `hysteria2` | `服务器, 端口` | `password` | `sni`、`skip-cert-verify`、`download-bandwidth`（Mbps） | M7（预研） |
| `tuic` / `tuic-v5` | `服务器, 端口` | `uuid`、`password` | `sni`、`alpn`、`skip-cert-verify` | M7（预研） |
| `wireguard` | — | `section-name` | 引用 `[WireGuard 名称]` 节 | M7（预研） |
| `snell`、`ssh`、`external`、`tailscale` 及其它 | — | — | 解析保留，节点标记不可用，`CFG-022` | 不支持 |

Shadowsocks `encrypt-method` 支持：`aes-128-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305`、`2022-blake3-aes-128-gcm`、`2022-blake3-aes-256-gcm`、`2022-blake3-chacha20-poly1305`（M3 后半）。流加密（`rc4-md5`、`aes-*-cfb`、`chacha20` 等）已不安全，给出 `CFG-023`，节点不可用。

VMess 的旧版（`alterId > 0`、非 AEAD 头）不支持，给出 `CFG-023`。

示例：

```ini
[Proxy]
HK-01 = ss, hk.example.com, 8388, encrypt-method=aes-128-gcm, password=secret, udp-relay=true
JP-WS = vmess, jp.example.com, 443, username=b831381d-6324-4d53-ad4f-8cda48b30811, tls=true, ws=true, ws-path=/ray, sni=jp.example.com
US-Trojan = trojan, us.example.com, 443, password=secret, sni=us.example.com
Office = https, proxy.corp.example, 443, alice, p@ss
```

## 6. [Proxy Group]

格式：`名称 = 类型, 成员…, key=value…`。成员是策略名（节点、其它组、内置策略）；`key=value` 形式的字段是参数，其余字段是成员。

### 6.1 类型

| 类型 | 选择方式 | 里程碑 |
| --- | --- | --- |
| `select` | 用户手动选择；默认第一个成员；选择按配置持久化 | M2 |
| `url-test` | 定期测速，选延迟最低者；新最低值比当前低于 `tolerance` 才切换 | M3 |
| `fallback` | 按成员顺序选第一个可用者 | M3 |
| `load-balance` | 在可用成员间分配连接；`persistent=true` 时同一主机固定到同一成员 | M3 |
| `subnet` | 按网络环境（SSID / 网络类型）选择 | M7 |

### 6.2 参数

| 参数 | 适用 | 类型 | 默认 | 说明 |
| --- | --- | --- | --- | --- |
| `policy-path` | 全部 | URL | 空 | 从外部资源加载节点列表（订阅），格式见 §12.4 |
| `update-interval` | 全部 | 秒 | `resource-update-interval` | `policy-path` 的更新间隔 |
| `policy-regex-filter` | 全部 | 正则 | 空 | 过滤来自 `policy-path`、`include-all-proxies`、`include-other-group` 的节点名 |
| `include-all-proxies` | 全部 | bool | `false` | 纳入 `[Proxy]` 中的全部节点 |
| `include-other-group` | 全部 | 引号内逗号分隔的组名 | 空 | 纳入这些组的成员（展开为节点，去重） |
| `hidden` | 全部 | bool | `false` | 不在策略页主列表显示 |
| `url` | url-test / fallback / load-balance | URL | `proxy-test-url` | |
| `interval` | 同上 | 秒 | `600` | 运行中周期测速间隔 |
| `timeout` | 同上 | 秒 | `test-timeout` | |
| `tolerance` | url-test | 毫秒 | `50` | |
| `evaluate-before-use` | url-test / fallback | bool | `false` | `false`：无测速结果时先用第一个成员并在后台测速；`true`：首次使用前等待测速（最多 `timeout`） |
| `persistent` | load-balance | bool | `false` | |

成员顺序：显式成员 → `include-other-group` → `include-all-proxies` → `policy-path`，去重后保留首次出现的位置。

示例：

```ini
[Proxy Group]
Proxy = select, Auto, HK-01, JP-WS, DIRECT
Auto = url-test, HK-01, JP-WS, US-Trojan, interval=600, tolerance=50
Airport = select, policy-path=https://sub.example.com/list?token=xxx, policy-regex-filter=(香港|HK), update-interval=43200
Streaming = fallback, JP-WS, US-Trojan, url=http://www.gstatic.com/generate_204
```

## 7. [Rule]

### 7.1 格式

```text
类型,值,策略[,选项…]
FINAL,策略[,dns-failed]
逻辑类型,(子规则…),策略
```

规则按顺序匹配，第一条命中的规则决定策略。语义与匹配算法见 [05](05-rule-engine.md)。

### 7.2 规则类型

| 类型 | 值 | 匹配对象 | iOS | 里程碑 |
| --- | --- | --- | --- | --- |
| `DOMAIN` | 域名 | 主机名完全相等 | ✓ | M1 |
| `DOMAIN-SUFFIX` | 域名 | 主机名等于该值或以 `.值` 结尾 | ✓ | M1 |
| `DOMAIN-KEYWORD` | 字符串 | 主机名包含该字符串 | ✓ | M1 |
| `DOMAIN-WILDCARD` | 通配 | 主机名匹配通配 | ✓ | M1 |
| `DOMAIN-SET` | URL / 路径 | 主机名属于域名集 | ✓ | M3 |
| `RULE-SET` | URL / 路径 / `LAN` | 规则集中任一规则命中 | ✓ | M1（`LAN`、本地）/ M3（URL） |
| `IP-CIDR` | IPv4 CIDR | 目标 IPv4 | ✓ | M1 |
| `IP-CIDR6` | IPv6 CIDR | 目标 IPv6 | ✓ | M1 |
| `GEOIP` | ISO 3166 国家代码 | 目标 IP 的国家 | ✓ | M3 |
| `IP-ASN` | ASN 数字 | 目标 IP 的 ASN | ✓ | M3 |
| `DEST-PORT` | `端口` 或 `起-止` | 目标端口 | ✓ | M1 |
| `IN-PORT` | `端口` 或 `起-止` | 入站监听端口 | ✓ | M2 |
| `PROTOCOL` | `TCP` / `UDP` / `HTTP` / `HTTPS` / `QUIC` | 流协议（HTTP/HTTPS/QUIC 依赖入口信息或嗅探） | ✓ | M2 |
| `HOSTNAME-TYPE` | `IPv4` / `IPv6` / `DOMAIN` / `SIMPLE` | 主机名形态 | ✓ | M1 |
| `SUBNET` | `SSID:名称`、`BSSID:地址`、`TYPE:WIFI\|CELLULAR\|WIRED` | 当前网络环境 | ✓ 🔬 | M4 |
| `USER-AGENT` | 通配 | 请求的 User-Agent（仅明文 HTTP 或 MitM 后可见） | ✓ | M2 |
| `URL-REGEX` | 正则 | 完整 URL（仅明文 HTTP 或 MitM 后可见） | ✓ | M2 |
| `AND` / `OR` / `NOT` | 子规则 | 逻辑组合 | ✓ | M1 |
| `SCRIPT` | 脚本名 | 规则脚本 | ✓ | M7 |
| `CELLULAR-RADIO` | `LTE` / `NR` 等 | 蜂窝制式 | 🔬 | M7 |
| `FINAL` | — | 兜底 | ✓ | M1 |
| `PROCESS-NAME`、`SRC-IP`、`SRC-PORT`、`DEVICE-NAME`、`MAC-ADDRESS` 等 | — | — | ✗ | 解析保留，`CFG-031`，不生效 |

### 7.3 逻辑规则

```ini
AND,((DOMAIN-SUFFIX,example.com),(DEST-PORT,443)),Proxy
OR,((DOMAIN-KEYWORD,ads),(DOMAIN-SUFFIX,doubleclick.net)),REJECT
NOT,((GEOIP,CN)),Proxy
AND,((OR,((DOMAIN,a.com),(DOMAIN,b.com))),(PROTOCOL,UDP)),DIRECT
```

解析要求：

- 用带括号深度与引号状态的分词器切分字段，**不得**用 `split(",")`。
- 第二个字段必须是一对外层括号，内部是若干 `(子规则)`，以逗号分隔；子规则不带策略字段，可以再嵌套逻辑规则。
- `NOT` 必须恰好有一个子规则。
- 子规则内的正则若包含括号或逗号，必须用引号包裹，例如 `(URL-REGEX,"^https://a\.com/(x|y)")`。

### 7.4 选项

| 选项 | 适用 | 说明 |
| --- | --- | --- |
| `no-resolve` | `IP-CIDR`、`IP-CIDR6`、`GEOIP`、`IP-ASN`、`RULE-SET` | 目标只有域名时不为本条规则发起 DNS 解析，直接视为不命中 |
| `update-interval=秒` | `RULE-SET`、`DOMAIN-SET` | 覆盖默认更新间隔 |
| `dns-failed` | `FINAL` | 规则匹配过程中 DNS 解析失败时，直接使用 FINAL 的策略 |
| `extended-matching` | 域名类 | 解析后忽略，`CFG-099`（Aether 默认对嗅探到的主机名进行域名匹配） |

### 7.5 FINAL

- 必须存在且应是最后一条。缺失时给出 `CFG-035` 并隐式追加 `FINAL,DIRECT`。
- 其后的规则给出 `CFG-036`，不会被匹配。

## 8. [Host]

格式：`模式 = 值`。模式是域名或域名通配。

| 值 | 含义 | 里程碑 |
| --- | --- | --- |
| `1.2.3.4`、`2001:db8::1`，或逗号分隔的多个地址 | 静态解析结果 | M2 |
| `other.example.com` | 别名：按 `other.example.com` 解析 | M2 |
| `server:IP[:端口]` / `server:system` / `server:https://…` / `server:tls://…` | 匹配的域名使用指定上游解析 | M3 |
| `server:script:<脚本名>` | 由 `type=dns` 的脚本给出解析结果（[09 §2](09-scripting.md#2-脚本类型与触发)） | M7 |

匹配顺序：完全匹配优先于通配；通配之间按文件顺序（模块条目在前，见 §12.2）。静态结果同样适用于 Fake IP 模式下的 `always-real-ip` 判断：命中静态 IP 的域名总是返回该 IP。

```ini
[Host]
router.lan = 192.168.1.1
*.corp.example = server:10.0.0.53
cdn.example.com = cdn.example.net
```

## 9. 重写类节（M5）

以下各节只对**可见的 HTTP 请求**生效：明文 HTTP，或主机命中 `[MITM] hostname` 且 MitM 已启用的 HTTPS。处理顺序见 [08 §5](08-mitm-rewrite.md#5-http-处理管线)。各节内部按顺序匹配，模块条目排在配置条目之前。

### 9.1 [URL Rewrite]

格式：`正则 替换 类型`（以空白分隔，含空白的字段用引号）。替换中可用 `$1`…`$9` 引用分组。结果 URL = 把原 URL 中**第一个匹配部分**替换为替换串，未匹配的前后部分保留；因此以 `^` 开头、只匹配前缀的正则可以只改写前缀。

| 类型 | 行为 |
| --- | --- |
| `302` / `307` | 返回重定向，`Location` 为替换后的 URL |
| `header` | 透明改写：把请求 URL 换成替换后的 URL 并更新 `Host`，客户端无感知；新主机按规则重新选择出站 |
| `reject` | 返回 404，空 Body |
| `reject-200` | 返回 200，空 Body |
| `reject-img` | 返回 200，1×1 透明 GIF |
| `reject-dict` | 返回 200，`{}`，`Content-Type: application/json` |
| `reject-array` | 返回 200，`[]`，`Content-Type: application/json` |
| `reject-drop` | 不响应，关闭连接 |

第一条命中的 URL 重写生效，之后不再匹配其它 URL 重写。

```ini
[URL Rewrite]
^https?://(www\.)?example\.com/old/(.*) https://example.com/new/$2 302
^https?://ad\.example\.com/ - reject-img
```

`reject` 类的替换字段无意义，惯例写 `-`。

### 9.2 [Header Rewrite]

格式：`[阶段] 正则 操作 参数…`。阶段为 `http-request`（默认）或 `http-response`。

| 操作 | 参数 | 行为 |
| --- | --- | --- |
| `header-add` | 名称 值 | 追加一个头 |
| `header-del` | 名称 | 删除所有同名头 |
| `header-replace` | 名称 值 | 同名头存在时替换其值（全部同名头合并为一个） |
| `header-replace-regex` | 名称 正则 替换 | 对同名头的值做正则替换 |

头名称不区分大小写。所有命中的头重写按顺序依次执行。

```ini
[Header Rewrite]
http-request ^https://api\.example\.com/ header-add X-Debug 1
http-response ^https://api\.example\.com/ header-del Set-Cookie
```

### 9.3 [Body Rewrite]

格式：`阶段 URL正则 正则1 替换1 [正则2 替换2 …]`。阶段为 `http-request` 或 `http-response`，必填。

- 只在 Body 不超过上限（默认 1 MiB，解压后计）时执行；超限时跳过并在请求记录中备注。
- Body 按 UTF-8 文本处理；非文本内容（依据 `Content-Type`，或解码失败）跳过并备注。
- 所有命中的 Body 重写按顺序依次执行。

```ini
[Body Rewrite]
http-response ^https://api\.example\.com/v1/config "\"ads\":true" "\"ads\":false"
```

### 9.4 [Map Local]

格式：`URL正则 参数…`，参数为 `key=value`，以空白分隔。

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `data-type` | `text` | `text` / `json` / `base64` / `file` / `tiny-gif` |
| `data` | 空 | `text`、`json`：内容；`base64`：Base64 内容；`file`：本地路径或 URL（作为外部资源下载） |
| `status-code` | `200` | |
| `header` | 按 `data-type` 推断 `Content-Type` | `名:值` 以 `\|` 分隔 |

命中后直接构造响应返回，不连接上游。

```ini
[Map Local]
^https://api\.example\.com/v1/banner data-type=json data="{\"items\":[]}"
```

## 10. [Script]

格式：`脚本名 = key=value, …`。脚本名在配置（含模块）内唯一。脚本运行时与 API 见 [09](09-scripting.md)。

| 参数 | 适用类型 | 默认 | 说明 |
| --- | --- | --- | --- |
| `type` | 全部 | 必需 | `http-request` / `http-response` / `cron` / `event` / `generic` / `dns`（M7）/ `rule`（M7） |
| `script-path` | 全部 | 必需 | URL 或本地路径（相对 `Scripts/`） |
| `script-update-interval` | 全部 | `86400` | 远程脚本更新间隔，秒 |
| `timeout` | 全部 | `10` | 秒 |
| `argument` | 全部 | 空 | 脚本中以 `$argument` 读取 |
| `debug` | 全部 | `false` | 每次执行重新读取脚本文件；`console` 输出写入请求备注 |
| `engine` | 全部 | — | 解析后忽略（只有 JavaScriptCore 引擎），`CFG-099` |
| `pattern` | http-request / http-response | 必需 | URL 正则 |
| `requires-body` | http-request / http-response | `false` | |
| `max-size` | http-request / http-response | `131072` | Body 上限（字节，解压后计）；超限时不执行脚本 |
| `binary-body-mode` | http-request / http-response | `false` | Body 以 `Uint8Array` 传入 |
| `cronexp` | cron | 必需 | 5 段 cron 表达式（分 时 日 月 周） |
| `event-name` | event | 必需 | 目前只有 `network-changed` |

```ini
[Script]
fix-config = type=http-response, pattern=^https://api\.example\.com/v1/config, requires-body=true, script-path=https://example.com/scripts/fix.js
daily-check = type=cron, cronexp="0 9 * * *", script-path=check.js, timeout=30
```

## 11. [MITM]

格式：`键 = 值`。

| 键 | 类型 | 默认 | 里程碑 | 说明 |
| --- | --- | --- | --- | --- |
| `hostname` | 列表 | 空 | M5 | 需要解密的主机，见下 |
| `skip-server-cert-verify` | bool | `false` | M5 | 不验证上游服务器证书 |
| `auto-quic-block` | bool | `true` | M5 | 拒绝发往 MitM 主机的 UDP 443，迫使客户端回退到 TCP |
| `h2` | bool | `false` | M7 | 与客户端协商 HTTP/2 |
| `ca-p12` | Base64 | 空 | M5 | 仅用于导入：PKCS#12 格式的 CA |
| `ca-passphrase` | 字符串 | 空 | M5 | 仅用于导入 |

`hostname` 列表项：

- `example.com`、`*.example.com`：通配匹配主机名，端口默认 443；
- `example.com:8443`：指定端口；`*:8443` 表示该端口上的所有主机；
- `-example.com`：排除，优先于所有包含项；
- 单独的 `*`：解密全部主机，给出 `CFG-070` 并在首页持续提示。

CA 默认存放在 Keychain 而不是配置中。导入带 `ca-p12` 的配置时，若设备上已有 CA，询问用户使用哪一个；Aether 渲染或导出配置时默认不写出这两个键。

## 12. 模块、托管配置与订阅

### 12.1 模块文件

```ini
#!name=示例模块
#!desc=演示模块语法
#!author=someone
#!homepage=https://example.com
#!arguments=region:HK,enable-log:false
#!arguments-desc=region：节点地区；enable-log：是否输出日志

[Rule]
DOMAIN-SUFFIX,example.org,{{{region}}}

[MITM]
hostname = %APPEND% api.example.org
```

| 元数据 | 说明 |
| --- | --- |
| `#!name` | 必需，显示名 |
| `#!desc`、`#!author`、`#!homepage`、`#!icon`、`#!category`、`#!version` | 可选，显示用 |
| `#!system` | 若声明且不含 `ios`，给出警告但仍可启用 |
| `#!arguments` | `名:默认值` 逗号分隔；正文中的 `{{{名}}}` 替换为参数值 |
| `#!arguments-desc` | 参数说明 |
| `#!requirement` | 解析后忽略，`CFG-082` |

模块允许的节：`[General]`、`[Rule]`、`[Host]`、`[URL Rewrite]`、`[Header Rewrite]`、`[Body Rewrite]`、`[Map Local]`、`[Script]`、`[MITM]`。其它节（尤其 `[Proxy]`、`[Proxy Group]`）给出 `CFG-080` 并忽略。

### 12.2 叠加语义

启用的模块按用户在模块列表中的顺序叠加，排在前面的模块优先级更高。

| 节 | 叠加方式 |
| --- | --- |
| `[General]`、`[MITM]` | `键 = 值` 替换；`键 = %APPEND% 值` 追加到列表末尾；`键 = %INSERT% 值` 插入到列表开头 |
| `[Rule]` | 所有模块的规则依次插到配置规则之前 |
| `[Host]`、`[URL Rewrite]`、`[Header Rewrite]`、`[Body Rewrite]`、`[Map Local]` | 模块条目排在配置条目之前 |
| `[Script]` | 合并；脚本名重复时保留先出现者，`CFG-062` |

模块规则引用不存在的策略时报 `CFG-011`，该模块整体不生效（其它模块与配置不受影响），并在模块列表中显示错误。

参数值与启用状态全局保存（所有配置共用），见 [11 §3](11-storage.md#3-文件布局)。

### 12.3 托管配置

配置第一行若为：

```text
#!MANAGED-CONFIG https://example.com/aether.conf interval=86400 strict=false
```

则该配置为托管配置：

- App 按 `interval`（秒）在前台或后台刷新时更新（见 [11 §5](11-storage.md#5-外部资源)），隧道运行时更新成功会自动重载。
- 托管配置在编辑器中只读；用户可"复制为本地配置"后编辑。
- `strict=true`：更新失败且距上次成功超过 `2 × interval` 时，在首页显示警告；不阻止使用。

### 12.4 节点订阅格式

`policy-path` 指向的内容自动识别以下格式（按此顺序尝试）：

1. **INI 代理行**：每行一个 `名称 = 类型, …`，可以带或不带 `[Proxy]` 节标题。
2. **YAML**：顶层对象含 `proxies` 数组（Clash 系格式）。字段映射见下表；未知类型跳过。
3. **URI 列表**：可先整体 Base64 解码（标准或 URL-safe，容忍缺失填充）；每行一个 URI。

| URI | 规范 | 映射 |
| --- | --- | --- |
| `ss://` | SIP002（`userinfo` 为 Base64 的 `method:password`，或 2022 方法的明文）；兼容整体 Base64 的旧格式；`plugin=obfs-local;obfs=http;obfs-host=…` | `ss` |
| `vmess://` | Base64 JSON（`v`、`ps`、`add`、`port`、`id`、`aid`、`net`、`type`、`host`、`path`、`tls`、`sni`） | `vmess`；`aid ≠ 0` 跳过；`net` 仅支持 `tcp`、`ws` |
| `trojan://` | `password@host:port?sni=&type=ws&path=&host=&allowInsecure=` | `trojan` |
| `vless://` | `uuid@host:port?security=tls&type=ws&path=&host=&sni=&flow=` | `vless`；`flow` 非空或 `security=reality` 跳过 |
| `hysteria2://`、`hy2://`、`tuic://` | 各自 URI 约定 | M7 前跳过 |

YAML `proxies` 字段映射：

| YAML `type` | 关键字段 → Aether 参数 |
| --- | --- |
| `ss` | `server`、`port`、`cipher`→`encrypt-method`、`password`、`udp`→`udp-relay`、`plugin: obfs` + `plugin-opts.mode/host` → `obfs`、`obfs-host` |
| `vmess` | `uuid`→`username`、`alterId`（≠0 跳过）、`cipher`→`encrypt-method`、`tls`、`servername`→`sni`、`skip-cert-verify`、`network: ws` + `ws-opts.path/headers` |
| `trojan` | `password`、`sni`、`skip-cert-verify`、`network: ws` + `ws-opts` |
| `vless` | `uuid`→`username`、`tls`、`servername`→`sni`、`network: ws` + `ws-opts`；`flow` 非空或 `reality-opts` 存在时跳过 |
| `http` / `socks5` | `username`、`password`、`tls`（→ `https` / `socks5-tls`）、`skip-cert-verify` |

节点名：取 URI 的 `#片段`（URL 解码）或 YAML 的 `name`；重名时追加 ` 2`、` 3`…；结果不得与配置中已有的策略名冲突（冲突时同样追加后缀）。

导入结果附带统计（成功数、跳过数及原因），在订阅详情中展示。

### 12.5 整份配置转换（M3）

导入 Clash 系 YAML 完整配置时，可转换为 Aether 配置：`proxies`→`[Proxy]`；`proxy-groups`（`select`、`url-test`、`fallback`、`load-balance`）→`[Proxy Group]`；`rules`→`[Rule]`（`MATCH`→`FINAL`，同名类型直接映射，`RULE-SET` 结合 `rule-providers` 转成 URL 形式）。无法转换的条目以注释形式保留在对应位置，并在开头写一段转换报告注释。

## 13. 诊断码

| 码 | 级别 | 含义 |
| --- | --- | --- |
| `CFG-001` | error | 文本无法按 UTF-8 解码 |
| `CFG-002` | warning | 未知节，原样保留 |
| `CFG-003` | warning | 未知键、参数或指令，原样保留 |
| `CFG-004` | error | 行语法错误（缺 `=`、引号未闭合、括号不匹配、条目出现在节外） |
| `CFG-005` | warning | `[General]` 键重复，后者生效 |
| `CFG-010` | error | 策略名重复或与内置策略冲突 |
| `CFG-011` | error | 引用了不存在的策略 |
| `CFG-012` | error | 策略组循环引用 |
| `CFG-013` | error | 策略组没有成员来源 |
| `CFG-020` | error | 参数值无效（类型或范围） |
| `CFG-021` | error | 缺少必需参数 |
| `CFG-022` | warning | 不支持的代理类型，节点不可用 |
| `CFG-023` | warning | 不支持的加密方式或协议变体，节点不可用 |
| `CFG-024` | info | 参数在 iOS 上无效，已忽略 |
| `CFG-030` | error | 未知规则类型 |
| `CFG-031` | warning | 规则类型在 iOS 上不支持，规则不生效 |
| `CFG-032` | error | CIDR 无效 |
| `CFG-033` | error | 正则表达式无效 |
| `CFG-034` | error | 端口或端口范围无效 |
| `CFG-035` | warning | 缺少 FINAL，已隐式追加 `FINAL,DIRECT` |
| `CFG-036` | warning | FINAL 之后的规则不会被匹配 |
| `CFG-037` | warning | 规则选项无效或不适用 |
| `CFG-040` | error | `[Host]` 条目无效 |
| `CFG-050` | error | 重写或 Map Local 条目无效 |
| `CFG-060` | error | 脚本定义缺少必需参数或类型无效 |
| `CFG-061` | error | cron 表达式无效 |
| `CFG-062` | warning | 脚本名重复，后出现者被忽略 |
| `CFG-070` | warning | MITM 主机名为 `*` |
| `CFG-071` | error | MITM 主机名模式无效 |
| `CFG-080` | warning | 模块包含不允许的节，已忽略 |
| `CFG-081` | error | 模块参数缺失且无默认值 |
| `CFG-082` | info | 模块 requirement 被忽略 |
| `CFG-090` | warning | 外部资源使用 HTTP |
| `CFG-091` | error | 外部资源 URL 无效 |
| `CFG-099` | info | 兼容性提示 |

有任何 `error` 级诊断的配置不得提交为运行包；`warning` 与 `info` 不阻止提交。每条诊断包含：码、级别、文件（配置或模块名）、行号、列号（可选）、参数（用于本地化消息插值）。

## 14. 兼容性

- **目标**：主流客户端的 INI 风格配置导入 Aether 后，所有 Aether 支持的部分行为一致；不支持的部分给出诊断并保留原文，再导出时原样写回。
- **未知内容**：未知节、键、参数、规则类型全部保留在 `ProfileDocument` 中，渲染时原样输出。
- **大小写**：节名、键名、规则类型、策略类型不区分大小写；策略名、主机名中的大小写在比较主机名时忽略，策略名区分大小写（与内置策略比较时不区分）。
- **兼容测试**：`Tests/Fixtures/profiles/compat/` 收集真实世界风格的配置（去除凭据），每个文件配一份期望的诊断列表与解析摘要，作为回归测试。

## 15. 解析器与模型实现要求

### 15.1 两层模型

```swift
/// 无损语法树：保留每一行的原文、位置和分类。
public struct ProfileDocument: Sendable {
    public var lines: [ProfileLine]                 // 全部行，按原顺序
    public var lineEnding: LineEnding               // .lf / .crlf
    public var hasBOM: Bool
    public func render() -> String                  // 未修改时与输入逐字节一致
    public func render(redactingSecrets: Bool) -> String
}

public struct ProfileLine: Sendable, Identifiable {
    public let id: LineID                           // 编辑期间稳定
    public var raw: String
    public var kind: Kind                           // .blank, .comment, .directive, .sectionHeader(name), .entry(Entry), .invalid
    public var sectionName: String?                 // 所属节（规范化名）
    public var location: SourceLocation             // 行号（1 起）
}

/// 类型化、已叠加模块、已校验的结果；不含编译后的匹配结构。
public struct ResolvedProfile: Sendable {
    public var general: GeneralSettings
    public var proxies: [ProxySpec]
    public var groups: [PolicyGroupSpec]
    public var rules: [RuleSpec]
    public var hosts: [HostSpec]
    public var urlRewrites: [URLRewriteSpec]
    public var headerRewrites: [HeaderRewriteSpec]
    public var bodyRewrites: [BodyRewriteSpec]
    public var mapLocals: [MapLocalSpec]
    public var scripts: [ScriptSpec]
    public var mitm: MITMSpec
    public var externalResources: [ExternalResourceRef]   // 所有需要下载的 URL 及其用途、更新间隔
    public var diagnostics: [Diagnostic]
    public var revision: String                           // 所有源文本与参数的 SHA-256
}
```

`RuleSpec` 是递归枚举，逻辑规则持有子规则数组；每条 `RuleSpec` 记录来源（文件、行号）与原文，用于请求详情与规则测试中的展示。

### 15.2 编辑

- 表单编辑通过 `ProfileDocument` 上的操作完成（如 `updateEntry(id:newValue:)`、`insertEntry(in:after:raw:)`、`removeEntry(id:)`、`moveEntry`），只改动目标行；新增行使用规范格式（`键 = 值`、`字段, 字段`）。
- 未修改的文档 `render()` 与输入逐字节一致；这条由往返测试覆盖全部 fixtures。
- 脱敏渲染替换以下值为 `******`：`password`、位置字段中的密码、`username`（UUID 类协议）、`uuid`、`token`、`ca-p12`、`ca-passphrase`、`http-api` 中的密钥、`policy-path` 与 `#!MANAGED-CONFIG` URL 的查询串。

### 15.3 性能

- 1 万行配置的解析 + 校验在 iPhone 上 < 200 ms；10 万条规则的规则集不经过本模块（由 [05](05-rule-engine.md) 的规则集加载器处理）。
- 解析器对任意输入不得崩溃或无限循环：M1 起为解析器提供模糊测试目标，CI 中至少运行固定种子的短时模糊测试。
