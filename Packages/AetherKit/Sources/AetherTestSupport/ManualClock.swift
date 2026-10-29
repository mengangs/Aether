import Foundation

/// 手动推进的时钟，供超时等时间相关逻辑的测试使用（CLAUDE.md：测试不依赖真实时间流逝）。
public final class ManualClock: Clock, @unchecked Sendable {
    public struct Instant: InstantProtocol, Hashable, Sendable {
        public var offset: Duration

        public init(offset: Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    public init() {}

    public var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public var minimumResolution: Duration { .zero }

    /// 正在等待的 sleep 数量。
    public var pendingSleeperCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepers.count
    }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// 推进时间，唤醒所有到期的 sleep。
    public func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleepers.filter { $0.value.deadline <= current }
        for key in due.keys {
            sleepers.removeValue(forKey: key)
        }
        lock.unlock()
        for sleeper in due.values {
            sleeper.continuation.resume()
        }
    }

    /// 等待至少 `count` 个 sleep 进入等待状态（让出执行权轮询，最多约 10 万次）。
    public func waitForSleepers(_ count: Int = 1) async {
        for _ in 0..<100_000 where pendingSleeperCount < count {
            await Task.yield()
        }
    }
}
