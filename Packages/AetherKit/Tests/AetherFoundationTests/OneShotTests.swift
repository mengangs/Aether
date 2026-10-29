import Foundation
import Testing

@testable import AetherFoundation

struct OneShotTests {
    @Test func firesExactlyOnceAcrossThreads() async {
        let calls = Locked(0)
        let once = OneShot<Int> { _ in calls.withLock { $0 += 1 } }
        await withTaskGroup(of: Bool.self) { group in
            for value in 0..<50 {
                group.addTask { once(value) }
            }
            var fired = 0
            for await result in group where result {
                fired += 1
            }
            #expect(fired == 1)
        }
        #expect(calls.current == 1)
        #expect(once.hasFired)
    }

    @Test func onceContinuationIgnoresSecondResume() async throws {
        let waiter = OnceContinuation<Int>()
        let value = try await withCheckedThrowingContinuation { continuation in
            waiter.start(continuation)
            waiter.resume(returning: 1)
            waiter.resume(returning: 2)
            waiter.resume(throwing: CancellationError())
        }
        #expect(value == 1)
    }

    @Test func cancelBeforeStartThrowsCancellation() async {
        let waiter = OnceContinuation<Int>()
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await withCheckedThrowingContinuation { waiter.start($0) }
        }
    }
}
