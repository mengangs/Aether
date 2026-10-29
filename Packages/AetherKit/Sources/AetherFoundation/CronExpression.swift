/// 5 段 cron 表达式（分 时 日 月 周），供配置校验（docs/04 §10，`CFG-061`）与 cron 脚本调度（docs/09 §2）共用。
///
/// 支持 `*`、单值、`a-b` 区间、`/步长`、逗号列表、月份与星期的英文缩写（`JAN`–`DEC`、`SUN`–`SAT`）；
/// 星期 0 与 7 都表示周日。日与周同时受限时按传统 cron 语义取并集。
public struct CronExpression: Sendable, Equatable, CustomStringConvertible {
    public let minutes: Set<Int>
    public let hours: Set<Int>
    public let daysOfMonth: Set<Int>
    public let months: Set<Int>
    /// 0 = 周日。
    public let daysOfWeek: Set<Int>
    let dayOfMonthRestricted: Bool
    let dayOfWeekRestricted: Bool
    public let source: String

    public enum ParseError: Error, Equatable, Sendable {
        case wrongFieldCount(Int)
        case invalidField(index: Int, text: String)
    }

    public init(_ text: String) throws {
        let fields = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard fields.count == 5 else { throw ParseError.wrongFieldCount(fields.count) }
        let months = ["JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC"]
        let weekdays = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        minutes = try Self.parseField(fields[0], index: 0, range: 0...59, names: [:])
        hours = try Self.parseField(fields[1], index: 1, range: 0...23, names: [:])
        daysOfMonth = try Self.parseField(fields[2], index: 2, range: 1...31, names: [:])
        self.months = try Self.parseField(
            fields[3], index: 3, range: 1...12,
            names: Dictionary(uniqueKeysWithValues: months.enumerated().map { ($1, $0 + 1) }))
        let week = try Self.parseField(
            fields[4], index: 4, range: 0...7,
            names: Dictionary(uniqueKeysWithValues: weekdays.enumerated().map { ($1, $0) }))
        daysOfWeek = Set(week.map { $0 == 7 ? 0 : $0 })
        dayOfMonthRestricted = fields[2] != "*" && fields[2] != "?"
        dayOfWeekRestricted = fields[4] != "*" && fields[4] != "?"
        source = fields.joined(separator: " ")
    }

    public var description: String { source }

    /// 某一时刻（分、时、日、月、周几）是否匹配。
    public func matches(minute: Int, hour: Int, day: Int, month: Int, weekday: Int) -> Bool {
        guard minutes.contains(minute), hours.contains(hour), months.contains(month) else { return false }
        let dayMatch = daysOfMonth.contains(day)
        let weekMatch = daysOfWeek.contains(weekday)
        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (true, true): return dayMatch || weekMatch
        case (true, false): return dayMatch
        case (false, true): return weekMatch
        case (false, false): return true
        }
    }

    static func parseField(_ text: String, index: Int, range: ClosedRange<Int>, names: [String: Int]) throws -> Set<Int>
    {
        var result: Set<Int> = []
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            guard !part.isEmpty else { throw ParseError.invalidField(index: index, text: text) }
            let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { throw ParseError.invalidField(index: index, text: text) }
            var step = 1
            if pieces.count == 2 {
                guard let value = Int(pieces[1]), value > 0, value <= range.upperBound else {
                    throw ParseError.invalidField(index: index, text: text)
                }
                step = value
            }
            let base = pieces[0]
            let lower: Int
            let upper: Int
            if base == "*" || base == "?" {
                lower = range.lowerBound
                upper = range.upperBound
            } else if let dash = base.firstIndex(of: "-") {
                guard let a = value(base[..<dash], names: names),
                    let b = value(base[base.index(after: dash)...], names: names),
                    a <= b
                else { throw ParseError.invalidField(index: index, text: text) }
                lower = a
                upper = b
            } else {
                guard let single = value(base, names: names) else {
                    throw ParseError.invalidField(index: index, text: text)
                }
                lower = single
                upper = pieces.count == 2 ? range.upperBound : single
            }
            guard range.contains(lower), range.contains(upper) else {
                throw ParseError.invalidField(index: index, text: text)
            }
            for value in stride(from: lower, through: upper, by: step) {
                result.insert(value)
            }
        }
        return result
    }

    private static func value(_ text: Substring, names: [String: Int]) -> Int? {
        if let number = Int(text), text.allSatisfy({ $0.isASCII && $0.isNumber }) { return number }
        return names[text.uppercased()]
    }
}
