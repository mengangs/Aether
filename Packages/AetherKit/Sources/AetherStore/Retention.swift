import AetherFoundation
import Foundation
import GRDB

/// 保留策略（docs/11 §4.2）。隧道每次启动时及每 6 小时执行一次。
public struct RetentionPolicy: Sendable, Equatable {
    public var trafficDailyDays = 400
    public var trafficHostDailyDays = 30
    public var requestHistoryDays = 7
    public var requestHistoryRows = 20_000
    public var ruleUsageDays = 90
    public var logbookDays = 30
    public var logbookRows = 5_000

    public init() {}

    public static let `default` = RetentionPolicy()
}

extension AetherDatabase {
    /// 按保留策略删除过期的行（单事务）。`now` 与时区注入，测试不依赖真实时间。
    /// - Returns: 删除的行数。
    @discardableResult
    public func prune(
        now: Date, timeZone: TimeZone = .current, policy: RetentionPolicy = .default
    ) async throws -> Int {
        func dayString(daysAgo: Int) -> String {
            TrafficDay.string(for: now.addingTimeInterval(-Double(daysAgo) * 86_400), timeZone: timeZone)
        }
        func cutoff(daysAgo: Int) -> Double {
            now.timeIntervalSince1970 - Double(daysAgo) * 86_400
        }
        let trafficCutoff = dayString(daysAgo: policy.trafficDailyDays)
        let hostCutoff = dayString(daysAgo: policy.trafficHostDailyDays)
        let historyCutoff = cutoff(daysAgo: policy.requestHistoryDays)
        let ruleCutoff = cutoff(daysAgo: policy.ruleUsageDays)
        let logbookCutoff = cutoff(daysAgo: policy.logbookDays)
        return try await write { db in
            var removed = 0
            try db.execute(sql: "DELETE FROM traffic_daily WHERE day < ?", arguments: [trafficCutoff])
            removed += db.changesCount
            try db.execute(sql: "DELETE FROM traffic_host_daily WHERE day < ?", arguments: [hostCutoff])
            removed += db.changesCount
            try db.execute(sql: "DELETE FROM request_history WHERE started_at < ?", arguments: [historyCutoff])
            removed += db.changesCount
            try db.execute(
                sql: """
                    DELETE FROM request_history WHERE id NOT IN
                      (SELECT id FROM request_history ORDER BY started_at DESC LIMIT ?)
                    """,
                arguments: [policy.requestHistoryRows])
            removed += db.changesCount
            try db.execute(sql: "DELETE FROM rule_usage WHERE last_hit_at < ?", arguments: [ruleCutoff])
            removed += db.changesCount
            try db.execute(sql: "DELETE FROM logbook WHERE at < ?", arguments: [logbookCutoff])
            removed += db.changesCount
            try db.execute(
                sql: "DELETE FROM logbook WHERE id NOT IN (SELECT id FROM logbook ORDER BY id DESC LIMIT ?)",
                arguments: [policy.logbookRows])
            removed += db.changesCount
            return removed
        }
    }
}
