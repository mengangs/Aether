import Foundation

/// 用互斥锁保护的值，供跨线程共享的少量可变状态使用（控制面计数、配置引用等）。
///
/// 部署目标 iOS 17 不能使用 `Synchronization.Mutex`，这里以 `NSLock` 实现；临界区内不得执行耗时操作或回调外部代码。
public final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    /// 在锁内读写值。
    @discardableResult
    public func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    /// 当前值的副本。
    public var current: Value {
        withLock { $0 }
    }
}
