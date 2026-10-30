import AetherFoundation
import AetherRules
import AetherStore
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import Testing

@testable import AetherEngine

@Suite("Traffic statistics (06 §12.1)")
struct TrafficStatisticsTests {
    private let utc = TimeZone(identifier: "UTC")!

    @Test("Totals, 1 Hz rate samples capped at 120, and 60 s flushes aggregated by day, policy and interface")
    func samplingAndFlush() {
        let loop = EmbeddedEventLoop()
        // 时钟随 EventLoop 推进：2026-10-30T23:59:00Z 起。
        let start = Date(timeIntervalSince1970: 1_793_404_740)
        let clock: @Sendable () -> Date = {
            start.addingTimeInterval(Double(loop.now.uptimeNanoseconds) / 1e9)
        }
        let network = NIOLockedValueBox(NetworkSnapshot(interfaceType: .wifi))
        let flushed = NIOLockedValueBox<[[TrafficDelta]]>([])
        let statistics = TrafficStatistics(
            eventLoop: loop, clock: clock, timeZone: utc, network: { network.withLockedValue { $0 } },
            sink: { deltas in flushed.withLockedValue { $0.append(deltas) } })
        statistics.start()

        statistics.record(policy: "Proxy", up: 100, down: 1000)
        statistics.record(policy: "Proxy", up: 50, down: 0)
        statistics.record(policy: "DIRECT", up: 0, down: 0)
        loop.advanceTime(by: .seconds(1))
        #expect(statistics.recentSamples.last?.up == 150 && statistics.recentSamples.last?.down == 1000)
        loop.advanceTime(by: .seconds(1))
        #expect(statistics.recentSamples.last?.up == 0)
        network.withLockedValue { $0.interfaceType = .cellular }
        statistics.record(policy: "Proxy", up: 1, down: 1)
        #expect(statistics.totalUp == 151 && statistics.totalDown == 1001)

        loop.advanceTime(by: .seconds(58))
        #expect(flushed.withLockedValue { $0.count } == 1)
        #expect(
            flushed.withLockedValue { $0.first } == [
                TrafficDelta(day: "2026-10-30", policy: "Proxy", interface: "cellular", up: 1, down: 1),
                TrafficDelta(day: "2026-10-30", policy: "Proxy", interface: "wifi", up: 150, down: 1000),
            ])
        // 跨过本地午夜：新的一天另起一行。
        statistics.record(policy: "Proxy", up: 7, down: 0)
        loop.advanceTime(by: .seconds(200))
        #expect(statistics.recentSamples.count == TrafficStatistics.sampleLimit)
        statistics.stop()
        let last = flushed.withLockedValue { $0.last }
        #expect(last == [TrafficDelta(day: "2026-10-31", policy: "Proxy", interface: "cellular", up: 7, down: 0)])
        // 停止后再无定时写入。
        loop.advanceTime(by: .seconds(120))
        #expect(flushed.withLockedValue { $0.count } == 2)
    }

    @Test("Beyond 1024 pending keys new keys count under (other) without losing bytes")
    func keyLimit() {
        let loop = EmbeddedEventLoop()
        let statistics = TrafficStatistics(eventLoop: loop, clock: { Date(timeIntervalSince1970: 0) }, timeZone: utc)
        for index in 0..<(TrafficStatistics.keyLimit + 10) {
            statistics.record(policy: "P\(index)", up: 1, down: 0)
        }
        let deltas = statistics.takePending()
        #expect(deltas.count == TrafficStatistics.keyLimit + 1)
        #expect(deltas.first { $0.policy == TrafficStatistics.overflowPolicy }?.up == 10)
        #expect(deltas.reduce(0) { $0 + $1.up } == UInt64(TrafficStatistics.keyLimit + 10))
        #expect(deltas.allSatisfy { $0.interface == "other" && $0.day == "1970-01-01" })
    }
}
