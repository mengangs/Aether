#if canImport(os)
    import Logging
    import os

    /// 写入 `os.Logger` 的处理器（docs/02 §8.2）。消息在进入日志前已按脱敏规则处理，因此以 public 方式记录。
    public struct OSLogHandler: LogHandler {
        public var metadata: Logging.Logger.Metadata = [:]
        public var metadataProvider: Logging.Logger.MetadataProvider?

        private let logger: os.Logger
        private let levelControl: LogLevelControl
        private var levelOverride: Logging.Logger.Level?

        public init(subsystem: String, category: String, levelControl: LogLevelControl) {
            logger = os.Logger(subsystem: subsystem, category: category)
            self.levelControl = levelControl
        }

        public var logLevel: Logging.Logger.Level {
            get { levelOverride ?? levelControl.level }
            set { levelOverride = newValue }
        }

        public subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
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
            var text = event.message.description
            for key in merged.keys.sorted() {
                if let value = merged[key] {
                    text += " \(key)=\(value)"
                }
            }
            logger.log(level: Self.osLevel(event.level), "\(text, privacy: .public)")
        }

        static func osLevel(_ level: Logging.Logger.Level) -> OSLogType {
            switch level {
            case .trace, .debug: return .debug
            case .info: return .info
            case .notice: return .default
            case .warning, .error: return .error
            case .critical: return .fault
            }
        }
    }
#endif
