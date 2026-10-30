import AetherFoundation
import Foundation
import GRDB

/// 日志簿条目（docs/11 §4.1 `logbook`）：隧道的重要事件，App 的诊断页展示。不得包含敏感信息。
public struct LogbookEntry: Sendable, Equatable, Codable {
    public enum Level: String, Sendable, Codable, CaseIterable {
        case info
        case warning
        case error
    }

    public enum Category: String, Sendable, Codable, CaseIterable {
        case tunnel
        case profile
        case resource
        case memory
        case mitm
        case script
    }

    /// 数据库行号（写入后才有）。
    public var id: Int64?
    public var at: Date
    public var level: Level
    public var category: Category
    /// 错误码（如 `NET-020`）。
    public var code: String?
    public var message: String
    /// JSON 文本。
    public var details: String?

    public init(
        id: Int64? = nil, at: Date, level: Level, category: Category, code: String? = nil, message: String,
        details: String? = nil
    ) {
        self.id = id
        self.at = at
        self.level = level
        self.category = category
        self.code = code
        self.message = message
        self.details = details
    }
}

extension AetherDatabase {
    /// 追加日志簿条目（单事务）。
    public func appendLogbook(_ entries: [LogbookEntry]) async throws {
        guard !entries.isEmpty else { return }
        try await write { db in
            let statement = try db.cachedStatement(
                sql: "INSERT INTO logbook (at, level, category, code, message, details) VALUES (?, ?, ?, ?, ?, ?)")
            for entry in entries {
                try statement.execute(arguments: [
                    entry.at.timeIntervalSince1970, entry.level.rawValue, entry.category.rawValue, entry.code,
                    entry.message, entry.details,
                ])
            }
        }
    }

    /// 最新的 `limit` 条日志簿条目，新的在前。
    public func recentLogbook(limit: Int = 200) async throws -> [LogbookEntry] {
        try await read { db in
            try Row.fetchAll(
                db, sql: "SELECT * FROM logbook ORDER BY id DESC LIMIT ?", arguments: [max(0, limit)]
            ).map { row in
                LogbookEntry(
                    id: row["id"], at: Date(timeIntervalSince1970: row["at"]),
                    level: LogbookEntry.Level(rawValue: row["level"]) ?? .info,
                    category: LogbookEntry.Category(rawValue: row["category"]) ?? .tunnel, code: row["code"],
                    message: row["message"], details: row["details"])
            }
        }
    }
}

/// 日志簿的批量写入（隧道侧，docs/11 §4.4）：条目先进缓冲，`flush` 时单事务写入。
///
/// 缓冲上限 `capacity`（256）条，超出时丢弃最旧的并计数；写入失败时丢弃这一批（日志簿不是关键数据）并计数。
public actor LogbookWriter {
    private let database: AetherDatabase
    private let capacity: Int
    private var buffer: [LogbookEntry] = []
    /// 因缓冲溢出或写入失败而丢弃的条目数。
    public private(set) var droppedEntries = 0

    public init(database: AetherDatabase, capacity: Int = 256) {
        self.database = database
        self.capacity = max(1, capacity)
    }

    public func add(_ entry: LogbookEntry) {
        if buffer.count >= capacity {
            buffer.removeFirst()
            droppedEntries += 1
        }
        buffer.append(entry)
    }

    /// 写入缓冲中的全部条目。
    public func flush() async {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll()
        do {
            try await database.appendLogbook(batch)
        } catch {
            droppedEntries += batch.count
        }
    }

    public var pendingCount: Int { buffer.count }
}
