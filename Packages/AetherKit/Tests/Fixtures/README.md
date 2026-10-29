# 测试数据

按 docs/13-testing.md §2 组织：

| 目录 | 内容 |
| --- | --- |
| `profiles/` | 配置文件（`.conf`）及其黄金文件（`.expected`） |
| `modules/` | 模块文件（`.amodule` / `.sgmodule`） |
| `rulesets/` | 规则集与域名集 |
| `dns/` | DNS 报文二进制 |
| `vectors/` | 密码学与协议测试向量，每个文件注明来源 |
| `certs/` | 测试证书（仅测试用，不得用于任何真实环境） |
| `scripts/` | 脚本兼容套件 |

域名只用 `example.com` / `example.net` / `example.org`，地址只用文档保留段（`192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24`、`2001:db8::/32`）。
