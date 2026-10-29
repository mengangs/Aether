import Foundation
import Logging

/// 日志基础设施（docs/02 §8.2）。统一使用 swift-log 门面：
/// Apple 平台写入 `os.Logger`（subsystem = Bundle ID 前缀，category = 日志标签），
/// 同时写入 App Group 中的滚动日志文件（2 个文件 × 1 MiB）。
///
/// 每个进程在启动早期调用一次 `bootstrap(_:)`。之后用 `Logger(label: "AetherEngine")` 等取得日志器，
/// 标签使用模块名。
public enum AetherLogging {
    /// 日志配置。
    public struct Configuration: Sendable {
        /// `os.Logger` 的 subsystem，取 Bundle ID 前缀。
        public var subsystem: String
        /// 滚动日志文件所在目录（App Group 中的 `Aether/Logs`）；为 nil 时只写系统日志。
        public var fileDirectory: URL?
        /// 日志文件名前缀：隧道为 `tunnel`，App 为 `app`。
        public var fileBaseName: String
        /// 初始级别，默认 `notice`。
        public var level: Logger.Level
        /// 单个日志文件上限。
        public var maxFileBytes: Int
        /// 是否写入系统日志（`os.Logger`）。非 Apple 平台忽略。
        public var writesToSystemLog: Bool

        public init(
            subsystem: String,
            fileDirectory: URL?,
            fileBaseName: String,
            level: Logger.Level = .notice,
            maxFileBytes: Int = RollingLogFile.defaultMaxFileBytes,
            writesToSystemLog: Bool = true
        ) {
            self.subsystem = subsystem
            self.fileDirectory = fileDirectory
            self.fileBaseName = fileBaseName
            self.level = level
            self.maxFileBytes = maxFileBytes
            self.writesToSystemLog = writesToSystemLog
        }
    }

    /// 运行时可调整的全局日志级别（配置 `loglevel` 与 IPC `setLogLevel` 修改它）。
    public static let levelControl = LogLevelControl(.notice)

    private static let bootstrapped = Locked(false)

    /// 安装日志后端。每个进程只生效一次，重复调用只更新级别。
    /// - Returns: 本次创建的滚动日志文件；未配置文件目录或已安装过时为 nil。
    @discardableResult
    public static func bootstrap(_ configuration: Configuration) -> RollingLogFile? {
        levelControl.level = configuration.level
        let first = bootstrapped.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return nil }
        let file = configuration.fileDirectory.map {
            RollingLogFile(
                directory: $0,
                baseName: configuration.fileBaseName,
                maxFileBytes: configuration.maxFileBytes
            )
        }
        LoggingSystem.bootstrap { label in
            makeHandler(label: label, configuration: configuration, file: file, levelControl: levelControl)
        }
        return file
    }

    /// 为一个日志标签构造处理器（`bootstrap` 内部使用，测试也直接调用）。
    public static func makeHandler(
        label: String,
        configuration: Configuration,
        file: RollingLogFile?,
        levelControl: LogLevelControl,
        clock: @escaping @Sendable () -> Date = Date.init
    ) -> any LogHandler {
        var handlers: [any LogHandler] = []
        if let file {
            handlers.append(FileLogHandler(label: label, file: file, levelControl: levelControl, clock: clock))
        }
        #if canImport(os)
            if configuration.writesToSystemLog {
                handlers.append(
                    OSLogHandler(subsystem: configuration.subsystem, category: label, levelControl: levelControl)
                )
            }
        #endif
        if handlers.count == 1, let only = handlers.first {
            return only
        }
        if handlers.isEmpty {
            return SwiftLogNoOpLogHandler()
        }
        return MultiplexLogHandler(handlers)
    }

    /// 解析配置或 IPC 中的级别名（`debug` / `info` / `notice` / `warning` / `error`，忽略大小写）。
    public static func level(named name: String) -> Logger.Level? {
        switch name.lowercased() {
        case "debug", "verbose": return .debug
        case "info": return .info
        case "notice": return .notice
        case "warning", "warn": return .warning
        case "error": return .error
        default: return nil
        }
    }
}

/// 进程内共享、可在运行时修改的日志级别。
public final class LogLevelControl: @unchecked Sendable {
    private let storage: Locked<Logger.Level>

    public init(_ level: Logger.Level) {
        storage = Locked(level)
    }

    public var level: Logger.Level {
        get { storage.current }
        set { storage.withLock { $0 = newValue } }
    }
}

/// 写入滚动日志文件的处理器。行格式：`<时间> <级别> [<标签>] <消息> key=value ...`。
public struct FileLogHandler: LogHandler {
    public var metadata: Logger.Metadata = [:]
    public var metadataProvider: Logger.MetadataProvider?

    private let label: String
    private let file: RollingLogFile
    private let levelControl: LogLevelControl
    private let clock: @Sendable () -> Date
    private var levelOverride: Logger.Level?

    public init(
        label: String,
        file: RollingLogFile,
        levelControl: LogLevelControl,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.label = label
        self.file = file
        self.levelControl = levelControl
        self.clock = clock
    }

    /// 未单独设置时跟随全局级别。
    public var logLevel: Logger.Level {
        get { levelOverride ?? levelControl.level }
        set { levelOverride = newValue }
    }

    public subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    public func log(event: LogEvent) {
        var merged = metadata
        if let provided = metadataProvider?.get() {
            merged.merge(provided) { _, new in new }
        }
        if let extra = event.metadata {
            merged.merge(extra) { _, new in new }
        }
        file.append(
            line: Self.format(
                date: clock(), level: event.level, label: label, message: event.message.description, metadata: merged))
    }

    static func format(date: Date, level: Logger.Level, label: String, message: String, metadata: Logger.Metadata)
        -> String
    {
        var line = "\(LogTimestamp.format(date)) \(level.rawValue) [\(label)] \(message)"
        for key in metadata.keys.sorted() {
            if let value = metadata[key] {
                line += " \(key)=\(value)"
            }
        }
        return line
    }
}
