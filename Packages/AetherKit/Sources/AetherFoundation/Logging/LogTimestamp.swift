import Foundation

/// 日志时间戳：UTC、毫秒精度的 ISO 8601（`2026-10-30T08:00:00.123Z`）。
///
/// 纯算术实现，不依赖 `DateFormatter`（非 Sendable、开销大），可在任意线程调用。
public enum LogTimestamp {
    public static func format(_ date: Date) -> String {
        let totalMilliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
        let millisecondsPerDay: Int64 = 86_400_000
        var days = totalMilliseconds / millisecondsPerDay
        var remainder = totalMilliseconds % millisecondsPerDay
        if remainder < 0 {
            remainder += millisecondsPerDay
            days -= 1
        }
        let (year, month, day) = civilDate(fromDaysSinceEpoch: days)
        let hour = remainder / 3_600_000
        let minute = remainder / 60_000 % 60
        let second = remainder / 1000 % 60
        let millisecond = remainder % 1000
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))T\(pad(hour, 2)):\(pad(minute, 2)):\(pad(second, 2))."
            + "\(pad(millisecond, 3))Z"
    }

    /// Howard Hinnant 的 civil_from_days 算法：1970-01-01 起的天数 → 公历年月日。
    static func civilDate(fromDaysSinceEpoch days: Int64) -> (Int64, Int64, Int64) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime < 10 ? monthPrime + 3 : monthPrime - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    private static func pad(_ value: Int64, _ width: Int) -> String {
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }
}
