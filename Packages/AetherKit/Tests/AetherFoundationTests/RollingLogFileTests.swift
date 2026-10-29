import Foundation
import Logging
import Testing

@testable import AetherFoundation

struct RollingLogFileTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-log-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func lines(_ url: URL) -> [String] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    private func size(_ url: URL) -> Int {
        (FileManager.default.contents(atPath: url.path) ?? Data()).count
    }

    @Test func createsDirectoryAndAppends() {
        let file = RollingLogFile(directory: directory, baseName: "tunnel", maxFileBytes: 1024)
        file.append(line: "first")
        file.append(line: "second")
        file.close()
        #expect(lines(file.currentFileURL) == ["first", "second"])
        #expect(!FileManager.default.fileExists(atPath: file.previousFileURL.path))
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func rotatesAndKeepsAtMostTwoFiles() throws {
        let file = RollingLogFile(directory: directory, baseName: "app", maxFileBytes: 256, maxLineBytes: 64)
        for index in 0..<200 {
            file.append(line: String(format: "line-%04d", index))
        }
        file.close()
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["app.0.log", "app.1.log"])
        #expect(size(file.currentFileURL) <= 256)
        #expect(size(file.previousFileURL) <= 256)
        // 最新的行在当前文件末尾，上一个文件紧接其前。
        let current = lines(file.currentFileURL)
        let previous = lines(file.previousFileURL)
        #expect(current.last == "line-0199")
        let combined = previous + current
        let numbers = combined.compactMap { Int($0.dropFirst(5)) }
        #expect(numbers == Array((200 - numbers.count)..<200))
        #expect(file.droppedLineCount == 0)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func reopensExistingFileAndContinuesSize() {
        let first = RollingLogFile(directory: directory, baseName: "t", maxFileBytes: 300)
        for _ in 0..<5 { first.append(line: String(repeating: "a", count: 49)) }
        first.close()
        let second = RollingLogFile(directory: directory, baseName: "t", maxFileBytes: 300)
        second.append(line: String(repeating: "b", count: 49))  // 250 + 50 = 300，不轮转
        second.append(line: String(repeating: "c", count: 49))  // 超出，轮转
        second.close()
        #expect(lines(second.previousFileURL).count == 6)
        #expect(lines(second.currentFileURL) == [String(repeating: "c", count: 49)])
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func truncatesLongLinesAtCharacterBoundary() {
        let data = RollingLogFile.encode(String(repeating: "数", count: 100), maxBytes: 64)
        let text = String(decoding: data, as: UTF8.self)
        #expect(data.count <= 64)
        #expect(text.hasSuffix("…[truncated]\n"))
        #expect(!text.contains("\u{FFFD}"))
    }

    @Test func escapesEmbeddedNewlines() {
        let text = String(decoding: RollingLogFile.encode("a\nb\rc", maxBytes: 64), as: UTF8.self)
        #expect(text == "a\\nb\\rc\n")
    }

    @Test func countsDroppedLinesWhenDirectoryIsUnusable() throws {
        // 用一个普通文件占住目录路径，使创建目录失败。
        try Data().write(to: directory)
        let file = RollingLogFile(directory: directory, baseName: "x", maxFileBytes: 1024)
        file.append(line: "lost")
        file.append(line: "lost again")
        #expect(file.droppedLineCount == 2)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func concurrentWritersProduceIntactLines() async {
        let file = RollingLogFile(directory: directory, baseName: "c", maxFileBytes: 1 << 20)
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<4 {
                group.addTask {
                    for index in 0..<250 {
                        file.append(line: "writer-\(writer)-line-\(index)-" + String(repeating: "x", count: 40))
                    }
                }
            }
        }
        file.close()
        let all = lines(file.currentFileURL)
        #expect(all.count == 1000)
        #expect(all.allSatisfy { $0.hasPrefix("writer-") && $0.hasSuffix(String(repeating: "x", count: 40)) })
        try? FileManager.default.removeItem(at: directory)
    }
}

struct FileLogHandlerTests {
    @Test func formatsLineWithSortedMetadata() {
        let line = FileLogHandler.format(
            date: Date(timeIntervalSince1970: 1_793_347_200.5),
            level: .notice,
            label: "AetherEngine",
            message: "tunnel started",
            metadata: ["revision": "12", "mode": "rule"]
        )
        #expect(line == "2026-10-30T08:00:00.500Z notice [AetherEngine] tunnel started mode=rule revision=12")
    }

    @Test func followsSharedLevelUnlessOverridden() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aether-handler-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let control = LogLevelControl(.notice)
        let file = RollingLogFile(directory: directory, baseName: "h", maxFileBytes: 4096)
        let handler = FileLogHandler(label: "Test", file: file, levelControl: control) {
            Date(timeIntervalSince1970: 0)
        }
        var logger = Logger(label: "Test") { _ in handler }
        logger.info("hidden")
        logger.notice("shown")
        control.level = .debug
        logger.debug("now shown")
        logger.logLevel = .error
        control.level = .trace
        logger.warning("hidden by override")
        file.close()
        let text = String(
            decoding: FileManager.default.contents(atPath: file.currentFileURL.path) ?? Data(), as: UTF8.self)
        #expect(
            text.split(separator: "\n").map(String.init) == [
                "1970-01-01T00:00:00.000Z notice [Test] shown",
                "1970-01-01T00:00:00.000Z debug [Test] now shown",
            ])
    }

    @Test(arguments: [
        ("debug", Logger.Level.debug), ("INFO", .info), ("notice", .notice), ("warning", .warning),
        ("warn", .warning), ("error", .error),
    ])
    func parsesLevelNames(_ name: String, _ level: Logger.Level) {
        #expect(AetherLogging.level(named: name) == level)
    }

    @Test func rejectsUnknownLevelName() {
        #expect(AetherLogging.level(named: "loud") == nil)
    }
}
