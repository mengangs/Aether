import Foundation

/// 只允许调用一次的回调包装（docs/06 §2.2：completion **恰好调用一次**）。重复调用被忽略并返回 false。
///
/// 系统回调（如 `startTunnel` 的 completionHandler）不是 Sendable；本类型以加锁保证跨线程只触发一次。
public final class OneShot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Value) -> Void)?

    public init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    /// 触发回调；已触发过时不做任何事。
    /// - Returns: 本次是否真正调用了回调。
    @discardableResult
    public func callAsFunction(_ value: Value) -> Bool {
        lock.lock()
        let pending = handler
        handler = nil
        lock.unlock()
        guard let pending else { return false }
        pending(value)
        return true
    }

    /// 是否已经触发。
    public var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handler == nil
    }
}

/// 可在任意线程、最多恢复一次的 continuation，用于把系统回调与任务取消桥接到 async/await。
///
/// 先取消（`cancel()`）后设置 continuation 时，continuation 会立即以 `CancellationError` 恢复。
public final class OnceContinuation<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var finished = false
    private var cancelledBeforeStart = false

    public init() {}

    /// 设置 continuation（在 `withCheckedThrowingContinuation` 的闭包中调用）。
    public func start(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if finished || cancelledBeforeStart {
            finished = true
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    public func resume(returning value: Value) {
        take()?.resume(returning: value)
    }

    public func resume(throwing error: any Error) {
        take()?.resume(throwing: error)
    }

    /// 任务取消时调用。
    public func cancel() {
        lock.lock()
        if continuation == nil, !finished {
            cancelledBeforeStart = true
            lock.unlock()
            return
        }
        lock.unlock()
        resume(throwing: CancellationError())
    }

    private func take() -> CheckedContinuation<Value, any Error>? {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, let pending = continuation else { return nil }
        finished = true
        continuation = nil
        return pending
    }
}

/// 把非 Sendable 的值（多为系统回调）带过并发边界。只在确认该值的使用是线程安全的场合使用，并注明理由。
public struct UncheckedSendable<Value>: @unchecked Sendable {
    public let value: Value

    public init(_ value: Value) {
        self.value = value
    }
}
