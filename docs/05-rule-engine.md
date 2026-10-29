# 05 规则引擎

`AetherRules` 把 `ResolvedProfile.rules` 编译成可快速匹配的 `RuleProgram`，并对每个流给出策略决定。规则语法见 [04 §7](04-profile-spec.md#7-rule)。

## 1. 接口

```swift
public struct RuleProgram: Sendable {
    public static func compile(
        _ specs: [RuleSpec],
        resources: RuleResourceProvider,      // 提供规则集 / 域名集 / MMDB 的已加载内容
        platform: PlatformCapabilities        // 声明 iOS 上哪些规则类型可用
    ) throws -> RuleProgram

    public func evaluate(_ context: RouteContext, from cursor: RuleCursor = .start) -> RuleStep
    public func evaluateWithTrace(_ context: RouteContext, resolver: (Hostname) -> [IPAddress]?) -> RuleTrace  // 仅规则测试工具使用
}

public enum RuleStep: Sendable {
    case decided(RuleMatch)
    case needsResolution(Hostname, resume: RuleCursor)   // 需要目标 IP 才能继续
}

public struct RuleMatch: Sendable {
    public let policy: String                 // 策略名（可能是策略组，由引擎继续解析）
    public let rule: RuleReference            // 序号、原文、来源文件与行号；FINAL 也是一条规则
    public let usedResolution: Bool
}
```

`evaluate` 是同步、无副作用、不分配大对象的纯函数，可以在 EventLoop 上直接调用。需要 DNS 时返回 `needsResolution`，由引擎异步解析后把结果写入上下文、从 `resume` 继续。

实现说明（M1-07）：

- 规则词汇类型（`RuleSpec`、`RuleCondition`、`RuleOptions`、`SourceReference` 等）放在 `AetherFoundation`：`AetherProfile` 产出它们，`AetherRules` 编译它们，两者互不依赖，保持 02 §3.2 的依赖方向。
- `RuleCursor` 带 `afterResolution` 标记，续算得到的 `RuleMatch.usedResolution` 据此为 true（即使需要 IP 的规则是第一条）。
- 单条规则的判定结果为 `RuleOutcome`：`match` / `noMatch` / `needsIP` / `undecidable(原因)`。判定时考虑"能否解析"（有主机名、尚无 IP、尚未失败、规则未带 `no-resolve`）：不能解析时 IP 类规则直接为不命中，因此 `NOT,((IP-CIDR,…))` 在只有 IP 字面量时也能正确判定。
- 数据库未加载时 `GEOIP` / `IP-ASN` 直接为不可判定，不会为它们发起解析。
- 规则集以 `RuleSetMatching` 协议接入（`CompiledRuleSet` 为实现：域名类合并为一个索引、IP 类合并为区间表、其余逐条）；未加载的规则集与域名集为不可判定。
- 决策缓存为 `RuleDecisionCache`（非线程安全，每个 EventLoop 一个），经 `evaluate(_:cache:)` 使用；键在 §4.3 基础上加入目标 IP（存在时），因为同一主机名的上下文可能带不同的 IP。

## 2. 匹配输入

```swift
public struct RouteContext: Sendable {
    public var host: Hostname?              // 规范化域名
    public var hostSource: HostSource       // .request / .fakeIP / .dnsReverse / .sniffed / .none
    public var destinationIP: IPAddress?
    public var destinationPort: UInt16
    public var transport: Transport         // .tcp / .udp
    public var appProtocol: AppProtocol     // .unknown / .http / .https / .quic
    public var inbound: InboundKind         // .tun / .httpProxy / .socks / .script(名称)
    public var inboundPort: UInt16?
    public var url: String?                 // 仅明文 HTTP 或 MitM 后可见
    public var userAgent: String?           // 同上
    public var network: NetworkSnapshot     // 接口类型、SSID、BSSID（可空）
    public var resolutionFailed: Bool       // 引擎在解析失败后置位
}
```

字段来源由引擎负责（见 [06 §6](06-network-engine.md#6-路由流程)）。规则引擎**不得**自行发起 DNS 或读取系统状态。

## 3. 匹配语义

### 3.1 总体顺序

1. 规则按最终顺序（模块规则在前，配置规则在后）逐条判定，第一条命中者决定策略。
2. FINAL 总是命中，作为最后一条。
3. 出站模式为"全局代理"或"直连"时，引擎不调用规则引擎。

### 3.2 每条规则的判定结果

| 结果 | 含义 |
| --- | --- |
| 命中 | 返回该规则的策略 |
| 不命中 | 继续下一条 |
| 需要 IP | 规则需要目标 IP，上下文只有域名，且规则未带 `no-resolve` → 返回 `needsResolution` |
| 不可判定 | 规则依赖的信息不可得（如 HTTPS 未解密时的 `URL-REGEX`、iOS 不支持的类型）→ 视为不命中，并在追踪中注明原因 |

解析之后继续判定时：

- 解析成功：`destinationIP` 写入第一个地址（优先 IPv4），后续 IP 类规则正常判定。
- 解析失败：置 `resolutionFailed = true`；如果 FINAL 带 `dns-failed`，立即以 FINAL 决定；否则后续 IP 类规则一律视为不命中。
- 一个流最多解析一次。

### 3.3 各类型细节

**域名规范化**（规则值与流的主机名都要做）：

- ASCII 转小写，去掉末尾的 `.`；
- 含非 ASCII 字符的标签先做 Unicode 小写化，再转为 Punycode（`xn--`，RFC 3492），比较一律用 A-label。不实现完整的 UTS #46 映射（兼容性分解、上下文规则等），对常见的中、日、韩及带重音字母的域名足够；实现见 `AetherFoundation.Hostname`；
- 原始拼写另存，仅用于展示。

| 类型 | 规则 |
| --- | --- |
| `DOMAIN` | 规范化后完全相等 |
| `DOMAIN-SUFFIX` | 相等，或主机名以 `.` + 值结尾。`notexample.com` **不**命中 `example.com` |
| `DOMAIN-KEYWORD` | 主机名包含值（子串） |
| `DOMAIN-WILDCARD` | `*` 匹配任意个字符（含 `.`），`?` 匹配一个字符；用迭代回溯的 glob 算法，不转换成正则 |
| `IP-CIDR` / `IP-CIDR6` | 数值比较。IPv4 映射的 IPv6 地址（`::ffff:a.b.c.d`）按 IPv4 处理 |
| `GEOIP` | MMDB 中查到的 `country.iso_code`（缺失时用 `registered_country.iso_code`）与值相等（不区分大小写）；未加载数据库 → 不可判定 |
| `IP-ASN` | MMDB 中的 `autonomous_system_number` 相等；未加载 → 不可判定 |
| `DEST-PORT` / `IN-PORT` | 单端口相等，或在闭区间内 |
| `PROTOCOL` | `TCP` / `UDP` 看传输层；`HTTP` / `HTTPS` / `QUIC` 看 `appProtocol` |
| `HOSTNAME-TYPE` | `IPv4` / `IPv6`：主机就是 IP 字面量（或只有目标 IP）；`DOMAIN`：含点的域名；`SIMPLE`：不含点的主机名 |
| `SUBNET` | `SSID:` / `BSSID:` 与当前 Wi-Fi 相等；`TYPE:` 与接口类型相等；信息不可得 → 不可判定 |
| `USER-AGENT` | 通配匹配；`userAgent` 为空 → 不可判定 |
| `URL-REGEX` | 正则在完整 URL 上搜索（非整串匹配）；`url` 为空 → 不可判定 |
| `RULE-SET` | 规则集内任一规则命中即命中；集内规则不带策略，可带 `no-resolve` |
| `DOMAIN-SET` | 主机名属于域名集（见 §6.2） |
| `AND` | 全部子规则命中。从左到右短路；遇到"需要 IP"时整体返回"需要 IP" |
| `OR` | 任一子规则命中。从左到右短路；所有子规则都不命中且其中有"需要 IP"时返回"需要 IP" |
| `NOT` | 子规则不命中则命中；子规则"需要 IP"则返回"需要 IP"；子规则"不可判定"则 `NOT` 也不可判定（不命中） |

### 3.4 哪些规则需要 IP

`IP-CIDR`、`IP-CIDR6`、`GEOIP`、`IP-ASN`，以及包含这些子规则的逻辑规则和规则集。带 `no-resolve` 的这些规则在没有 IP 时直接视为不命中。

Fake IP 地址**不是**真实目标 IP：引擎在构造上下文时，如果目标地址属于 Fake IP 段，`destinationIP` 置空、`host` 填入反查到的域名（见 [07 §3](07-dns.md#3-fake-ip)）。

## 4. 编译与数据结构

### 4.1 分块

首条命中语义要求保留顺序，但逐条线性匹配在规则多时太慢。编译时把规则序列切成**块**：连续的、同一类别的简单规则合并为一个块，块内建立索引，块内多条命中时取序号最小者。

| 类别 | 包含 | 块内索引 |
| --- | --- | --- |
| 域名类 | `DOMAIN`、`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`DOMAIN-WILDCARD` | 精确：哈希表；后缀：排序反转域名表（§4.2）；关键字：≤ 32 个时线性，否则 Aho-Corasick；通配：线性 |
| IP 类 | `IP-CIDR`、`IP-CIDR6` | 区间表：排序、合并重叠区间（保留最小序号），二分查找 |
| 单条 | 其余所有类型（含规则集、域名集、逻辑规则、GEOIP） | 无，逐条判定；规则集与域名集各自内部有索引 |

匹配时按块顺序判定，第一个产生命中的块给出结果。真实配置中块数通常在几十以内。

### 4.2 排序反转域名表

后缀匹配与域名集共用此结构：

- 每个域名按标签反转（`www.example.com` → `com.example.www`），存入一块连续的 UTF-8 缓冲；另有偏移数组（`UInt32`）和规则序号 / 标志数组。
- 条目按反转串排序。查询 `a.b.example.com` 时依次二分查找 `com.example.b.a`、`com.example.b`、`com.example`、`com`，命中后检查该条目是"后缀"还是"精确"标志。
- 内存约为"域名总字节数 + 每条 8 字节"。10 万条域名的目标占用 ≤ 3 MiB。

### 4.3 决策缓存

- LRU，容量 4096，键为 `(host 或 IP, 目标端口, 传输层, 应用协议, 入站端口, 网络环境修订号)`。
- 只缓存"纯"决策：判定过程中没有解析 DNS、没有遇到依赖 URL / User-Agent / 脚本的规则。
- 缓存只存规则序号；策略组的选择变化不影响缓存。运行配置替换时整个缓存随旧 `RuleProgram` 一起丢弃。

### 4.4 编译约束

- 编译在控制面（非 EventLoop）执行。
- 大型规则集的编译结果可缓存到磁盘（见 §6.4），隧道启动时优先加载缓存。
- 编译失败的单个外部规则集不影响其它规则：该规则视为不可判定并记录 `RES` 类错误，配置其它部分照常生效。

## 5. 性能目标

在 iPhone（A15 级别）上，Release 构建：

| 场景 | 目标 |
| --- | --- |
| 5,000 条普通规则 + 3 个各 5 万条的规则集，单次未命中缓存的判定 | p99 < 50 µs |
| 命中缓存的判定 | < 2 µs |
| 10 万条域名集的编译 | < 1 s；加载编译缓存 < 100 ms |
| 上述全部规则的常驻内存 | ≤ 8 MiB |

性能测试在 macOS / Linux 上以基准测试的形式持续跟踪，真机数据在 M3、M7 各记录一次。

## 6. 规则集与域名集

### 6.1 规则集格式

文本，每行一条不带策略的规则：

```text
# 注释
DOMAIN-SUFFIX,example.com
DOMAIN-KEYWORD,tracker
IP-CIDR,203.0.113.0/24,no-resolve
AND,((DOMAIN-SUFFIX,example.net),(DEST-PORT,443))
```

- 允许的类型：域名类、`IP-CIDR`、`IP-CIDR6`、`GEOIP`、`IP-ASN`、`DEST-PORT`、`PROTOCOL`、`USER-AGENT`、`URL-REGEX`、逻辑规则。不允许 `RULE-SET`、`DOMAIN-SET`、`FINAL`（忽略并计数）。
- 不支持的类型（如 `PROCESS-NAME`）跳过并计数，不使整个规则集失败。
- 规则集内规则的相对顺序无意义（任一命中即命中），因此编译时可以把同类规则全部合并为一个索引。
- 引用时写在 `RULE-SET` 上的 `no-resolve` 作用于集内全部 IP 类规则。

### 6.2 域名集格式

每行一个域名：

- `.example.com`：匹配 `example.com` 自身及其全部子域名；
- `example.com`：只匹配 `example.com`；
- `#` 开头为注释；空行忽略；无效行跳过并计数。

### 6.3 内置规则集 `LAN`

`RULE-SET,LAN,DIRECT` 等价于以下内容（不需要下载）：

```text
IP-CIDR,10.0.0.0/8
IP-CIDR,100.64.0.0/10
IP-CIDR,127.0.0.0/8
IP-CIDR,169.254.0.0/16
IP-CIDR,172.16.0.0/12
IP-CIDR,192.168.0.0/16
IP-CIDR,224.0.0.0/4
IP-CIDR,255.255.255.255/32
IP-CIDR6,::1/128
IP-CIDR6,fc00::/7
IP-CIDR6,fe80::/10
IP-CIDR6,ff00::/8
DOMAIN-SUFFIX,local
HOSTNAME-TYPE,SIMPLE
```

### 6.4 加载与缓存

- 远程规则集与域名集是外部资源，下载、缓存与更新见 [11 §5](11-storage.md#5-外部资源)。
- 大小上限 32 MiB（解压后），条目上限 50 万；超限时拒绝加载并记录错误。
- 编译缓存文件 `Resources/<资源哈希>.ruleset.bin`：文件头含魔数、格式版本、源内容 SHA-256；任何一项不符即丢弃重建。格式版本在数据结构变化时递增。

## 7. GeoIP 与 ASN

### 7.1 数据库读取

`AetherRules` 内置一个 MaxMind DB（MMDB）格式读取器：

- 按公开的 MaxMind DB 格式规范实现：元数据定位、搜索树遍历（记录宽度 24 / 28 / 32 位，IPv4 子树起点）、数据段解码（指针、字符串、双精度、字节、各宽度无符号整数、有符号 32 位、映射、数组、布尔、单精度）。
- 文件以只读内存映射方式打开，不整体读入内存。
- 查询结果缓存：LRU 2048 条（IP → 国家代码 / ASN）。
- 对损坏文件必须安全失败（越界检查、循环指针检测），不得崩溃。

### 7.2 数据来源

- Aether 不随包附带数据库。用户在 `[General]` 中配置 `geoip-db-url`、`ipasn-db-url`，或在设置页从推荐来源中选择（例如 DB-IP Lite 系列，CC BY 4.0，需在"关于"中署名）。
- 资源下载支持 `.gz` 解压。
- 配置包含 `GEOIP` / `IP-ASN` 规则而没有可用数据库时，首页与配置诊断中提示"GeoIP 数据库未配置"，规则视为不可判定。

## 8. 可解释性

### 8.1 请求记录中的匹配信息

每个流记录：命中规则的序号、原文、来源（配置名或模块名 + 行号）、是否发生解析、从规则策略到最终节点的策略链（如 `Proxy → Auto → HK-01`）。

### 8.2 规则测试工具

App 与 `aether-cli match` 提供：输入主机名、URL 或 IP，可选端口、协议、网络环境；输出逐条追踪：

```text
#12 DOMAIN-SUFFIX,google.com,Proxy        不命中
#13 RULE-SET,https://…/ads.list,REJECT    不命中（集内 48,211 条）
#14 GEOIP,CN,DIRECT                       需要 IP → 解析 www.example.com = 93.184.215.14
#14 GEOIP,CN,DIRECT                       不命中（US）
#15 FINAL,Proxy                           命中
策略链：Proxy → Auto → JP-WS
```

追踪模式逐条判定、不使用块索引与缓存，结果必须与正常模式一致——这一点由测试保证（同一输入下两种模式的命中序号相同）。

### 8.3 命中统计

引擎在内存中按规则身份计数，每 60 秒合并写入数据库（[11 §4](11-storage.md#4-数据库)）。规则身份为"来源 + 规范化原文"的哈希，不使用行号（编辑配置后行号会变）。

## 9. 测试要求

| 测试 | 内容 |
| --- | --- |
| 后缀边界 | `notexample.com` 不命中 `DOMAIN-SUFFIX,example.com`；`a.example.com`、`example.com` 命中 |
| 规范化 | `WWW.Example.COM.` 命中 `DOMAIN,www.example.com`；Unicode 域名与其 Punycode 形式互相命中 |
| CIDR 边界 | 区间首尾与相邻地址；IPv6；IPv4 映射地址 |
| 顺序 | 两条均可命中时序号小者胜，跨块亦然 |
| no-resolve | 只有域名时不返回 `needsResolution` |
| 解析恢复 | `needsResolution` 后从 cursor 继续，结果与"一开始就有 IP"一致 |
| dns-failed | 解析失败直接落到 FINAL |
| 逻辑规则 | 嵌套 AND/OR/NOT；子规则中带逗号和括号的引号正则 |
| 不可判定 | `URL-REGEX` 无 URL、`PROCESS-NAME` 在 iOS 上 |
| 一致性 | 随机生成规则与输入，块索引模式与逐条模式结果相同（属性测试） |
| 规则集 | 含无效行、不支持类型、超大文件 |
| MMDB | 官方测试数据库文件（MaxMind 公开的测试用 MMDB）上的查询；截断与损坏文件 |
