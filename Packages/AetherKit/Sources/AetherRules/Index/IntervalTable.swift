import AetherFoundation

/// 128 位无符号整数（IPv6 地址的数值形式），只实现区间表所需的运算。
public struct UInt128Value: Comparable, Hashable, Sendable {
    public var high: UInt64
    public var low: UInt64

    public init(high: UInt64, low: UInt64) {
        self.high = high
        self.low = low
    }

    public static func < (lhs: UInt128Value, rhs: UInt128Value) -> Bool {
        (lhs.high, lhs.low) < (rhs.high, rhs.low)
    }

    var successor: UInt128Value? {
        if low == .max {
            return high == .max ? nil : UInt128Value(high: high + 1, low: 0)
        }
        return UInt128Value(high: high, low: low + 1)
    }
}

/// 可在区间表中使用的离散值。
public protocol IntervalBound: Comparable, Hashable, Sendable {
    /// 下一个值；已是最大值时为 nil。
    var nextValue: Self? { get }
    /// 前一个值；已是最小值时为 nil。
    var previousValue: Self? { get }
}

extension UInt32: IntervalBound {
    public var nextValue: UInt32? { self == .max ? nil : self + 1 }
    public var previousValue: UInt32? { self == 0 ? nil : self - 1 }
}

extension UInt128Value: IntervalBound {
    public var nextValue: UInt128Value? { successor }

    public var previousValue: UInt128Value? {
        if low > 0 { return UInt128Value(high: high, low: low - 1) }
        return high == 0 ? nil : UInt128Value(high: high - 1, low: .max)
    }
}

/// 区间表（docs/05 §4.1）：把可能重叠的闭区间展开为不重叠的段，每段记录覆盖它的区间中的最小值；二分查找。
public struct IntervalTable<Bound: IntervalBound>: Sendable {
    private var starts: [Bound] = []
    private var ends: [Bound] = []
    private var values: [Int32] = []

    public var segmentCount: Int { starts.count }

    public init(_ intervals: [(lower: Bound, upper: Bound, value: Int)]) {
        let sorted = intervals.filter { $0.lower <= $0.upper }.sorted { $0.lower < $1.lower }
        // 边界点：每个区间的起点与终点的后继。相邻边界点之间（含起点、不含下一点）覆盖集合不变。
        var pointSet: Set<Bound> = []
        for interval in sorted {
            pointSet.insert(interval.lower)
            if let next = interval.upper.nextValue { pointSet.insert(next) }
        }
        let points = pointSet.sorted()
        var active: [(upper: Bound, value: Int32)] = []
        var cursor = 0
        for (index, point) in points.enumerated() {
            while cursor < sorted.count, sorted[cursor].lower <= point {
                active.append((sorted[cursor].upper, Int32(clamping: sorted[cursor].value)))
                cursor += 1
            }
            active.removeAll { $0.upper < point }
            guard let best = active.map(\.value).min() else { continue }
            let segmentEnd: Bound
            if index + 1 < points.count, let end = points[index + 1].previousValue {
                segmentEnd = end
            } else if let maxUpper = active.map(\.upper).max() {
                segmentEnd = maxUpper
            } else {
                continue
            }
            // 与前一段相邻且值相同则合并。
            if let lastValue = values.last, lastValue == best, let lastEnd = ends.last, lastEnd.nextValue == point {
                ends[ends.count - 1] = segmentEnd
            } else {
                starts.append(point)
                ends.append(segmentEnd)
                values.append(best)
            }
        }
    }

    /// 查找包含 `value` 的段的最小值。
    public func lookup(_ value: Bound) -> Int? {
        var low = 0
        var high = starts.count - 1
        var candidate = -1
        while low <= high {
            let mid = (low + high) / 2
            if starts[mid] <= value {
                candidate = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard candidate >= 0, value <= ends[candidate] else { return nil }
        return Int(values[candidate])
    }
}

extension IPAddress {
    /// IPv4（含映射地址）的数值；不是 IPv4 时为 nil。
    var ipv4Value: UInt32? {
        if case .v4(let v4) = unmappedIPv4 { return v4.value }
        return nil
    }

    /// IPv6 的数值；IPv4 及映射地址返回 nil。
    var ipv6Value: UInt128Value? {
        if case .v6(let v6) = unmappedIPv4 { return UInt128Value(high: v6.high, low: v6.low) }
        return nil
    }
}
