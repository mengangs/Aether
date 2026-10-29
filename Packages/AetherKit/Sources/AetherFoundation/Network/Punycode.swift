/// Punycode（RFC 3492）编解码，供域名的 IDNA A-label 转换使用。
public enum Punycode {
    private static let base = 36
    private static let tMin = 1
    private static let tMax = 26
    private static let skew = 38
    private static let damp = 700
    private static let initialBias = 72
    private static let initialN = 128
    /// 单个标签的输入上限（码点数），防止恶意输入导致超长计算。
    static let maxInputScalars = 1024

    /// 编码一个标签的 Unicode 码点序列（不含 `xn--` 前缀）。溢出或超长时返回 nil。
    public static func encode(_ input: some StringProtocol) -> String? {
        let scalars = Array(input.unicodeScalars)
        guard scalars.count <= maxInputScalars else { return nil }
        var output = scalars.filter { $0.isASCII }.map { Character($0) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 {
            output.append("-")
        }
        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < scalars.count {
            guard let m = scalars.map({ Int($0.value) }).filter({ $0 >= n }).min() else { return nil }
            let (product, overflow1) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow1 else { return nil }
            let (sum, overflow2) = delta.addingReportingOverflow(product)
            guard !overflow2 else { return nil }
            delta = sum
            n = m
            for scalar in scalars {
                let c = Int(scalar.value)
                if c < n {
                    delta += 1
                    guard delta > 0 else { return nil }
                }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta: delta, numPoints: handled + 1, firstTime: handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(output)
    }

    /// 解码 Punycode（不含 `xn--` 前缀）。格式错误、溢出或结果为无效码点时返回 nil。
    public static func decode(_ input: some StringProtocol) -> String? {
        let characters = Array(input.unicodeScalars)
        guard characters.count <= maxInputScalars * 4, characters.allSatisfy(\.isASCII) else { return nil }
        var output: [UnicodeScalar] = []
        var start = 0
        if let lastDash = characters.lastIndex(of: "-") {
            output = Array(characters[..<lastDash])
            start = lastDash + 1
        }
        var n = initialN
        var i = 0
        var bias = initialBias
        var position = start
        while position < characters.count {
            let oldI = i
            var w = 1
            var k = base
            while true {
                guard position < characters.count, let d = value(of: characters[position]) else { return nil }
                position += 1
                let (product, overflow1) = d.multipliedReportingOverflow(by: w)
                guard !overflow1 else { return nil }
                let (sum, overflow2) = i.addingReportingOverflow(product)
                guard !overflow2 else { return nil }
                i = sum
                let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                if d < t { break }
                let (nextW, overflow3) = w.multipliedReportingOverflow(by: base - t)
                guard !overflow3 else { return nil }
                w = nextW
                k += base
            }
            bias = adapt(delta: i - oldI, numPoints: output.count + 1, firstTime: oldI == 0)
            let (quotient, overflow4) = n.addingReportingOverflow(i / (output.count + 1))
            guard !overflow4 else { return nil }
            n = quotient
            i %= output.count + 1
            guard n <= 0x10FFFF, let scalar = UnicodeScalar(UInt32(n)) else { return nil }
            output.insert(scalar, at: i)
            guard output.count <= maxInputScalars else { return nil }
            i += 1
        }
        var result = ""
        result.unicodeScalars.append(contentsOf: output)
        return result
    }

    private static func adapt(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    private static func digit(_ value: Int) -> Character {
        value < 26 ? Character(UnicodeScalar(UInt8(97 + value))) : Character(UnicodeScalar(UInt8(22 + value)))
    }

    private static func value(of scalar: UnicodeScalar) -> Int? {
        switch scalar.value {
        case 0x30...0x39: return Int(scalar.value) - 22
        case 0x41...0x5A: return Int(scalar.value) - 0x41
        case 0x61...0x7A: return Int(scalar.value) - 0x61
        default: return nil
        }
    }
}
