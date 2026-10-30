import AetherFoundation
import Foundation
import GRDB

/// 一段时间内某天、某最终节点、某接口类型的流量增量（docs/06 §12.1），合并写入 `traffic_daily`。
public struct TrafficDelta: Sendable, Equatable, Hashable {
    /// 本地日期 `YYYY-MM-DD`。
    public var day: String
    /// 最终节点名（DIRECT、节点名）。
    public var policy: String
    /// `wifi` / `cellular` / `wired` / `other`。
    public var interface: String
    public var up: UInt64
    public var down: UInt64

    public init(day: String, policy: String, interface: String, up: UInt64, down: UInt64) {
        self.day = day
        self.policy = policy
        self.interface = interface
        self.up = up
        self.down = down
    }
}

/// 本地日期（docs/11 §4.1 的 `day` 列）。
public enum TrafficDay {
    /// `date` 在 `timeZone` 中的公历日期 `YYYY-MM-DD`。
    public static func string(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let text = String(value)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

extension AetherDatabase {
    /// 合并流量增量（单事务；同一主键累加）。
    public func mergeTraffic(_ deltas: [TrafficDelta]) async throws {
        guard !deltas.isEmpty else { return }
        try await write { db in
            let statement = try db.cachedStatement(
                sql: """
                    INSERT INTO traffic_daily (day, policy, interface, up, down) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (day, policy, interface) DO UPDATE SET up = up + excluded.up, down = down + excluded.down
                    """)
            for delta in deltas {
                try statement.execute(arguments: [
                    delta.day, delta.policy, delta.interface, Int64(clamping: delta.up), Int64(clamping: delta.down),
                ])
            }
        }
    }

    /// `traffic_daily` 中 `from...to`（含）的行，按日期、节点、接口排序。
    public func trafficDaily(from: String, to: String) async throws -> [TrafficDelta] {
        try await read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT day, policy, interface, up, down FROM traffic_daily
                    WHERE day >= ? AND day <= ? ORDER BY day, policy, interface
                    """,
                arguments: [from, to]
            ).map { row in
                TrafficDelta(
                    day: row["day"], policy: row["policy"], interface: row["interface"],
                    up: UInt64(max(0, row["up"] as Int64)), down: UInt64(max(0, row["down"] as Int64)))
            }
        }
    }
}
