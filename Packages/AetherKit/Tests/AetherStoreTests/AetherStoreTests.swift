import Foundation
import Testing

@testable import AetherStore

@Test func moduleIdentity() {
    #expect(AetherStoreModule.name == "AetherStore")
    #expect(AetherStoreModule.dependencies.count == 1)
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("aether-store-\(UUID().uuidString)")
}

private let utc = TimeZone(identifier: "UTC")!
/// 2026-10-30T12:00:00Z
private let now = Date(timeIntervalSince1970: 1_793_361_600)

@Suite("Database migrations (11 §4.3)")
struct MigrationTests {
    @Test("v1_initial creates every table of 11 §4.1 in a WAL database; reopening is idempotent")
    func initialMigration() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AetherDatabase.open(directory: directory)
        #expect(try await database.appliedMigrations() == ["v1_initial"])
        #expect(
            try await database.tableNames() == [
                "logbook", "request_history", "rule_usage", "script_store", "traffic_daily", "traffic_host_daily",
            ])
        #expect(try await database.journalMode() == "wal")
        try await database.mergeTraffic([
            TrafficDelta(day: "2026-10-30", policy: "DIRECT", interface: "wifi", up: 1, down: 2)
        ])

        let reopened = try AetherDatabase.open(directory: directory)
        #expect(try await reopened.appliedMigrations() == ["v1_initial"])
        #expect(try await reopened.trafficDaily(from: "2026-10-30", to: "2026-10-30").count == 1)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("aether.sqlite").path))
    }

    @Test("An unusable location fails with STO-002")
    func unusableLocation() throws {
        let file = temporaryDirectory()
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: StoreError.self) { try AetherDatabase.open(directory: file) }
        do {
            _ = try AetherDatabase.open(directory: file)
        } catch let error as StoreError {
            #expect(error.code == .stoDatabaseUnavailable)
        }
    }
}

@Suite("Traffic and logbook storage")
struct StorageTests {
    @Test("Traffic deltas accumulate per day, policy and interface")
    func trafficMerge() async throws {
        let database = try AetherDatabase.inMemory()
        try await database.mergeTraffic([
            TrafficDelta(day: "2026-10-29", policy: "Proxy", interface: "wifi", up: 10, down: 100),
            TrafficDelta(day: "2026-10-30", policy: "DIRECT", interface: "cellular", up: 1, down: 2),
        ])
        try await database.mergeTraffic([
            TrafficDelta(day: "2026-10-30", policy: "DIRECT", interface: "cellular", up: 5, down: 7),
            TrafficDelta(day: "2026-10-30", policy: "DIRECT", interface: "wifi", up: UInt64(Int64.max) + 1, down: 0),
        ])
        let rows = try await database.trafficDaily(from: "2026-10-30", to: "2026-10-30")
        #expect(
            rows == [
                TrafficDelta(day: "2026-10-30", policy: "DIRECT", interface: "cellular", up: 6, down: 9),
                TrafficDelta(day: "2026-10-30", policy: "DIRECT", interface: "wifi", up: UInt64(Int64.max), down: 0),
            ])
        #expect(try await database.trafficDaily(from: "2026-10-01", to: "2026-10-31").count == 3)
    }

    @Test("Local days are formatted in the given time zone")
    func trafficDay() {
        #expect(TrafficDay.string(for: now, timeZone: utc) == "2026-10-30")
        #expect(TrafficDay.string(for: now, timeZone: TimeZone(secondsFromGMT: 13 * 3600)!) == "2026-10-31")
        #expect(TrafficDay.string(for: Date(timeIntervalSince1970: 0), timeZone: utc) == "1970-01-01")
    }

    @Test("Logbook entries round-trip newest first; the writer buffers at most 256 entries")
    func logbook() async throws {
        let database = try AetherDatabase.inMemory()
        let writer = LogbookWriter(database: database, capacity: 3)
        for index in 0..<5 {
            writer.add(
                LogbookEntry(
                    at: now.addingTimeInterval(Double(index)), level: index == 4 ? .error : .info,
                    category: .tunnel, code: index == 4 ? "NET-050" : nil, message: "event \(index)"))
        }
        #expect(writer.droppedEntries == 2)
        #expect(writer.pendingCount == 3)
        #expect(await writer.flush() == 3)
        #expect(writer.pendingCount == 0)
        let entries = try await database.recentLogbook()
        #expect(entries.map(\.message) == ["event 4", "event 3", "event 2"])
        #expect(entries.first?.level == .error && entries.first?.code == "NET-050")
        #expect(entries.first?.at == now.addingTimeInterval(4))
        #expect(try await database.recentLogbook(limit: 1).count == 1)
    }
}

@Suite("Retention (11 §4.2)")
struct RetentionTests {
    @Test("Old rows are pruned by age and the row caps hold")
    func prune() async throws {
        let database = try AetherDatabase.inMemory()
        @Sendable func day(_ daysAgo: Int) -> String {
            TrafficDay.string(for: now.addingTimeInterval(-Double(daysAgo) * 86_400), timeZone: utc)
        }
        try await database.mergeTraffic([
            TrafficDelta(day: day(401), policy: "P", interface: "wifi", up: 1, down: 1),
            TrafficDelta(day: day(399), policy: "P", interface: "wifi", up: 1, down: 1),
        ])
        var policy = RetentionPolicy()
        policy.logbookRows = 2
        policy.requestHistoryRows = 1
        try await database.write { db in
            for (daysAgo, host) in [(31, "old"), (29, "new")] {
                try db.execute(
                    sql: "INSERT INTO traffic_host_daily (day, host, policy) VALUES (?, ?, 'P')",
                    arguments: [day(daysAgo), host])
            }
            for (index, daysAgo) in [8.0, 1.0, 0.5].enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO request_history (id, started_at, inbound, transport, app_protocol, destination,
                          policy_chain, mitm, bytes_up, bytes_down, state) VALUES (?, ?, 'tun', 'tcp', 'unknown',
                          '192.0.2.1:443', '[]', 0, 0, 0, 'completed')
                        """,
                    arguments: ["s-\(index)", now.timeIntervalSince1970 - daysAgo * 86_400])
            }
            for (key, daysAgo) in [("stale", 91.0), ("fresh", 3.0)] {
                try db.execute(
                    sql: """
                        INSERT INTO rule_usage (rule_key, rule_text, source, hits, last_hit_at) VALUES (?, ?, 'p', 1, ?)
                        """,
                    arguments: [key, key, now.timeIntervalSince1970 - daysAgo * 86_400])
            }
        }
        try await database.appendLogbook(
            [40.0, 3, 2, 1].map {
                LogbookEntry(
                    at: now.addingTimeInterval(-$0 * 86_400), level: .info, category: .tunnel, message: "\($0)")
            })

        let removed = try await database.prune(now: now, timeZone: utc, policy: policy)
        #expect(try await database.trafficDaily(from: "0000-00-00", to: "9999-99-99").map(\.day) == [day(399)])
        let remaining = try await database.read { db in
            (
                try String.fetchAll(db, sql: "SELECT host FROM traffic_host_daily"),
                try String.fetchAll(db, sql: "SELECT id FROM request_history"),
                try String.fetchAll(db, sql: "SELECT rule_key FROM rule_usage")
            )
        }
        #expect(remaining.0 == ["new"])
        #expect(remaining.1 == ["s-2"])
        #expect(remaining.2 == ["fresh"])
        #expect(try await database.recentLogbook().map(\.message) == ["1.0", "2.0"])
        #expect(removed == 1 + 1 + 1 + 1 + 1 + 1 + 1)
    }
}
