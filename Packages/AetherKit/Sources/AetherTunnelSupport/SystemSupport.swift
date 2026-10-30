import AetherFoundation
import CAetherTunnel
import Darwin

/// utun 描述符（docs/06 §4.1）。
public enum UTun {
    /// `setTunnelNetworkSettings` 完成后查找 utun 控制 socket 的描述符；找不到时为 nil（改用备用桥接）。
    public static func findDescriptor() -> Int32? {
        let descriptor = aether_find_utun_descriptor()
        return descriptor >= 0 ? descriptor : nil
    }
}

/// 系统 DNS 服务器（docs/07 §4.1）：libresolv 的 `res_ninit` / `res_getservers`，最多 16 个。
public enum SystemDNS {
    public static func servers() -> [IPAddress] {
        let capacity = 16
        var buffer = [CChar](repeating: 0, count: capacity * 64)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            Int(aether_copy_system_dns_servers(pointer.baseAddress, Int32(capacity)))
        }
        return (0..<max(0, min(count, capacity))).compactMap { index in
            let slot = buffer[(index * 64)..<(index * 64 + 64)]
            let bytes = slot.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return IPAddress(String(decoding: bytes, as: UTF8.self))
        }
    }
}

/// 进程资源上限（docs/06 §2.2 第 1 步）。
public enum ResourceLimits {
    /// 把 `RLIMIT_NOFILE` 的软限制提高到 `min(硬限制, target)`（不降低已有的软限制），返回生效的软限制；
    /// 读取失败时为 nil。每个 TUN TCP 连接占用 3 个描述符，默认的 256 远远不够。
    @discardableResult
    public static func raiseOpenFileLimit(to target: UInt64 = 8192) -> UInt64? {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return nil }
        let desired = min(rlim_t(target), limit.rlim_max)
        if limit.rlim_cur < desired {
            var raised = limit
            raised.rlim_cur = desired
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 {
                limit = raised
            }
        }
        return UInt64(limit.rlim_cur)
    }
}
