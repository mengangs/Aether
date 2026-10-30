// Apple 平台隧道的系统接口胶水（docs/06 §4.1、§11）。只在 Apple 平台编译。
//
// utun 描述符查找需要的内核控制结构（ctl_info、sockaddr_ctl、CTLIOCGINFO、AF_SYSTEM）不在 iOS SDK 的公开头文件中，
// 在 CAetherTunnel.c 里按内核 ABI（xnu bsd/sys/kern_control.h、sys/sys_domain.h）自行声明，不调用私有 API。

#ifndef CAETHER_TUNNEL_H
#define CAETHER_TUNNEL_H

#include <stddef.h>

/// 在 0…1024 的描述符中查找 utun 控制 socket：`getpeername` 地址族为 AF_SYSTEM，且控制 ID 等于
/// `com.apple.net.utun_control` 的 ID。找不到时返回 -1。
int aether_find_utun_descriptor(void);

/// 系统 DNS 服务器地址的文本形式（libresolv `res_ninit` / `res_getservers`）。每个地址最长 64 字节（含结尾 0）。
/// 写入最多 `capacity` 个地址到 `out`（`capacity * 64` 字节），返回写入的个数；失败时返回 0。
int aether_copy_system_dns_servers(char *out, int capacity);

#endif
