import AetherFoundation
import Foundation
import GRDB

/// Aether 的 SQLite 数据库（docs/11 §4）：App Group 中的 `Database/aether.sqlite`，GRDB `DatabasePool`（WAL 模式）。
///
/// App 与隧道打开数据库时都运行迁移器（幂等）。隧道侧写入批量合并、单事务内完成；App 侧只做短事务（docs/11 §4.4）。
/// 全部读写方法都是 async 的，在 GRDB 自己的队列上执行，不阻塞调用方线程。
public final class AetherDatabase: Sendable {
    /// 数据库文件名（位于 `SharedContainer.database`）。
    public static let fileName = "aether.sqlite"

    let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// 打开（必要时创建）`directory/aether.sqlite` 并运行迁移。
    /// - Throws: `STO-002`：目录无法创建、文件无法打开或迁移失败。
    public static func open(directory: URL) throws -> AetherDatabase {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.label = "Aether"
            let pool = try DatabasePool(
                path: directory.appendingPathComponent(fileName).path, configuration: configuration)
            try migrator.migrate(pool)
            return AetherDatabase(writer: pool)
        } catch {
            throw StoreError(.stoDatabaseUnavailable, "Cannot open the database: \(error)")
        }
    }

    /// 内存数据库（预览与测试）。
    public static func inMemory() throws -> AetherDatabase {
        do {
            let queue = try DatabaseQueue()
            try migrator.migrate(queue)
            return AetherDatabase(writer: queue)
        } catch {
            throw StoreError(.stoDatabaseUnavailable, "Cannot create the in-memory database: \(error)")
        }
    }

    /// 迁移（docs/11 §4.3）：只追加、按名称标识，发布后不得修改。`v1_initial` 一次建出 11 §4.1 的全部表。
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.execute(
                sql: """
                    CREATE TABLE traffic_daily (
                      day TEXT NOT NULL,
                      policy TEXT NOT NULL,
                      interface TEXT NOT NULL,
                      up INTEGER NOT NULL DEFAULT 0,
                      down INTEGER NOT NULL DEFAULT 0,
                      PRIMARY KEY (day, policy, interface)
                    );
                    CREATE TABLE traffic_host_daily (
                      day TEXT NOT NULL,
                      host TEXT NOT NULL,
                      policy TEXT NOT NULL,
                      up INTEGER NOT NULL DEFAULT 0,
                      down INTEGER NOT NULL DEFAULT 0,
                      requests INTEGER NOT NULL DEFAULT 0,
                      PRIMARY KEY (day, host, policy)
                    );
                    CREATE TABLE request_history (
                      id TEXT PRIMARY KEY,
                      started_at REAL NOT NULL,
                      ended_at REAL,
                      inbound TEXT NOT NULL,
                      transport TEXT NOT NULL,
                      app_protocol TEXT NOT NULL,
                      host TEXT,
                      destination TEXT NOT NULL,
                      method TEXT,
                      url TEXT,
                      status INTEGER,
                      rule TEXT,
                      policy_chain TEXT NOT NULL,
                      mitm INTEGER NOT NULL,
                      bytes_up INTEGER NOT NULL,
                      bytes_down INTEGER NOT NULL,
                      state TEXT NOT NULL,
                      error_code TEXT,
                      notes TEXT
                    );
                    CREATE INDEX request_history_started ON request_history (started_at);
                    CREATE TABLE rule_usage (
                      rule_key TEXT PRIMARY KEY,
                      rule_text TEXT NOT NULL,
                      source TEXT NOT NULL,
                      hits INTEGER NOT NULL DEFAULT 0,
                      last_hit_at REAL NOT NULL
                    );
                    CREATE TABLE logbook (
                      id INTEGER PRIMARY KEY AUTOINCREMENT,
                      at REAL NOT NULL,
                      level TEXT NOT NULL,
                      category TEXT NOT NULL,
                      code TEXT,
                      message TEXT NOT NULL,
                      details TEXT
                    );
                    CREATE TABLE script_store (
                      key TEXT PRIMARY KEY,
                      value TEXT NOT NULL,
                      updated_at REAL NOT NULL
                    );
                    """)
        }
        return migrator
    }

    /// 已执行的迁移名（按执行顺序）。
    public func appliedMigrations() async throws -> [String] {
        try await read { db in try Self.migrator.appliedIdentifiers(db).sorted() }
    }

    /// 用户表名（迁移测试与诊断）。
    public func tableNames() async throws -> [String] {
        try await read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name
                    """)
        }
    }

    /// 日志模式（`DatabasePool` 为 `wal`）。
    public func journalMode() async throws -> String {
        try await read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "" }
    }

    func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await writer.read(body)
        } catch {
            throw StoreError(.stoDatabaseFailed, "\(error)")
        }
    }

    func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await writer.write(body)
        } catch {
            throw StoreError(.stoDatabaseFailed, "\(error)")
        }
    }
}
