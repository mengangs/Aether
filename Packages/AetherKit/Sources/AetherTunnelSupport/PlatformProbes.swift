import AetherFoundation
import Darwin
import Foundation

#if os(iOS)
    import os
#endif

/// 进程内存读数（docs/02 §6）：footprint 取自 `task_info(TASK_VM_INFO).phys_footprint`；剩余额度在 iOS 上取自
/// `os_proc_available_memory()`，其它平台为 nil。不硬编码扩展的内存上限。
public enum MemoryProbe {
    public static func read() -> (footprint: UInt64?, available: UInt64?) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
        #if os(iOS)
            let available: UInt64? = UInt64(max(0, os_proc_available_memory()))
        #else
            let available: UInt64? = nil
        #endif
        return (footprint, available)
    }
}

/// Darwin 通知（docs/10 §3）：状态快照与日志簿更新后通知 App 与小组件。
public enum DarwinNotifier {
    public static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(rawValue: name as CFString), nil, nil, true)
    }
}

/// 一次性信号：`signal()` 之后 `wait` 立即返回；`wait(timeout:)` 超时返回 false。
final class ExitSignal: Sendable {
    private struct State {
        var signaled = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Locked(State())

    func signal() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.signaled = true
            defer { state.waiters.removeAll() }
            return state.waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// 等待信号，最多 `timeout`；返回是否收到信号。
    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    let resumeNow = self.state.withLock { state -> Bool in
                        if state.signaled { return true }
                        state.waiters.append(continuation)
                        return false
                    }
                    if resumeNow {
                        continuation.resume()
                    }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            if !first {
                // 超时：唤醒仍在等待的子任务，使任务组能结束。
                self.signal()
            }
            return first
        }
    }
}
