import Foundation

/// 滚动日志文件（docs/02 §8.2）：`<目录>/<名称>.0.log` 为当前文件，`<名称>.1.log` 为上一个文件，共 2 个文件。
///
/// 上限与溢出行为：
/// - 写入一行后若当前文件会超过 `maxFileBytes`，先把当前文件改名为 `.1`（覆盖旧的 `.1`），再新建 `.0`；
///   因此磁盘占用不超过 `2 × maxFileBytes`；
/// - 单行超过 `maxLineBytes` 时在 UTF-8 字符边界截断，并以 `…[truncated]` 结尾；
/// - 写入失败（磁盘满、目录不可用等）时丢弃该行并计入 `droppedLineCount`，下次写入重新打开文件，不向调用方抛错。
///
/// 线程安全：内部加锁，可被多个 `LogHandler` 并发使用。
public final class RollingLogFile: @unchecked Sendable {
    public static let defaultMaxFileBytes = 1 << 20
    public static let defaultMaxLineBytes = 4096

    public let directory: URL
    public let baseName: String
    public let maxFileBytes: Int
    public let maxLineBytes: Int

    private let lock = NSLock()
    private var handle: FileHandle?
    private var currentSize = 0
    private var dropped = 0

    public init(
        directory: URL,
        baseName: String,
        maxFileBytes: Int = RollingLogFile.defaultMaxFileBytes,
        maxLineBytes: Int = RollingLogFile.defaultMaxLineBytes
    ) {
        self.directory = directory
        self.baseName = baseName
        self.maxFileBytes = max(maxFileBytes, 256)
        self.maxLineBytes = max(min(maxLineBytes, self.maxFileBytes), 64)
    }

    deinit {
        try? handle?.close()
    }

    /// 当前文件。
    public var currentFileURL: URL { directory.appendingPathComponent("\(baseName).0.log") }
    /// 上一个文件。
    public var previousFileURL: URL { directory.appendingPathComponent("\(baseName).1.log") }

    /// 因写入失败而丢弃的行数。
    public var droppedLineCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dropped
    }

    /// 追加一行（自动补换行符）。
    public func append(line: String) {
        let data = Self.encode(line, maxBytes: maxLineBytes)
        lock.lock()
        defer { lock.unlock() }
        do {
            if handle == nil {
                try open()
            }
            if currentSize > 0, currentSize + data.count > maxFileBytes {
                try rotate()
            }
            guard let handle else {
                dropped += 1
                return
            }
            try handle.write(contentsOf: data)
            currentSize += data.count
        } catch {
            dropped += 1
            try? handle?.close()
            handle = nil
        }
    }

    /// 关闭文件；之后再次写入会重新打开。
    public func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.close()
        handle = nil
    }

    // MARK: - 内部

    private func open() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = currentFileURL
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: Self.fileAttributes) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let opened = try FileHandle(forWritingTo: url)
        currentSize = Int(try opened.seekToEnd())
        handle = opened
    }

    private func rotate() throws {
        try handle?.close()
        handle = nil
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: previousFileURL.path) {
            try fileManager.removeItem(at: previousFileURL)
        }
        try fileManager.moveItem(at: currentFileURL, to: previousFileURL)
        currentSize = 0
        try open()
    }

    private static var fileAttributes: [FileAttributeKey: Any]? {
        #if os(iOS)
            return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
            return nil
        #endif
    }

    /// 编码一行：去掉内部换行，超长时在字符边界截断。
    static func encode(_ line: String, maxBytes: Int) -> Data {
        let marker = "…[truncated]"
        var text = line.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        if text.utf8.count + 1 > maxBytes {
            let budget = maxBytes - 1 - marker.utf8.count
            var used = 0
            var cut = text.startIndex
            for index in text.indices {
                let size = text[index].utf8.count
                if used + size > budget { break }
                used += size
                cut = text.index(after: index)
            }
            text = String(text[..<cut]) + marker
        }
        return Data((text + "\n").utf8)
    }
}
