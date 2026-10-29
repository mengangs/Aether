/// 通配匹配（docs/04 §3.2、05 §3.3）：`*` 匹配任意个任意字符（含 `.`），`?` 匹配一个字符；不区分 ASCII 大小写。
/// 迭代回溯算法，不转换成正则，最坏 O(n·m)。
public enum Wildcard {
    public static func matches(_ pattern: some StringProtocol, _ text: some StringProtocol) -> Bool {
        let p = Array(pattern.unicodeScalars)
        let t = Array(text.unicodeScalars)
        var pi = 0
        var ti = 0
        var starPattern = -1
        var starText = 0
        while ti < t.count {
            if pi < p.count, p[pi] == "?" || equal(p[pi], t[ti]) {
                pi += 1
                ti += 1
            } else if pi < p.count, p[pi] == "*" {
                starPattern = pi
                starText = ti
                pi += 1
            } else if starPattern >= 0 {
                pi = starPattern + 1
                starText += 1
                ti = starText
            } else {
                return false
            }
        }
        while pi < p.count, p[pi] == "*" {
            pi += 1
        }
        return pi == p.count
    }

    private static func equal(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        if a == b { return true }
        guard a.isASCII, b.isASCII else { return false }
        return lower(a.value) == lower(b.value)
    }

    private static func lower(_ value: UInt32) -> UInt32 {
        (0x41...0x5A).contains(value) ? value + 0x20 : value
    }
}
