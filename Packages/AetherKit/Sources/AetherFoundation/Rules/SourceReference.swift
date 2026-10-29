/// 条目的来源：文件（配置或模块名）、行号与原文。用于请求详情、规则测试与诊断中的展示（docs/04 §15.1）。
public struct SourceReference: Hashable, Sendable, Codable, CustomStringConvertible {
    public var file: String
    public var line: Int
    /// 条目原文（去首尾空白）。
    public var raw: String

    public init(file: String, line: Int, raw: String) {
        self.file = file
        self.line = line
        self.raw = raw
    }

    public var description: String { "\(file):\(line)" }
}
