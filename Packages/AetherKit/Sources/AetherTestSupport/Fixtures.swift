import Foundation

/// 测试数据访问（docs/13 §2）。只供测试 target 依赖，产品代码不得依赖本模块（架构检查会拒绝）。
///
/// 测试数据放在 `Packages/AetherKit/Tests/Fixtures/`，按源码路径定位，因此测试必须在源码树中运行。
public enum Fixtures {
    /// `Tests/Fixtures` 目录。
    public static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Sources/AetherTestSupport
        .deletingLastPathComponent()  // Sources
        .deletingLastPathComponent()  // AetherKit
        .appendingPathComponent("Tests/Fixtures", isDirectory: true)

    /// 相对 `Tests/Fixtures` 的文件地址，如 `vectors/blake3/test_vectors.json`。
    public static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    public static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    public static func string(_ relativePath: String) throws -> String {
        try String(decoding: data(relativePath), as: UTF8.self)
    }
}

/// 十六进制编解码，测试向量常用。
public enum Hex {
    /// 解码十六进制字符串（大小写均可，忽略空白）；格式错误时返回 nil。
    public static func decode(_ string: String) -> [UInt8]? {
        let digits = string.unicodeScalars.filter { !$0.properties.isWhitespace }
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var high: UInt8?
        for scalar in digits {
            guard let value = nibble(scalar) else { return nil }
            if let h = high {
                bytes.append(h << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return bytes
    }

    public static func encode<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        let table = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        for byte in bytes {
            out.append(table[Int(byte >> 4)])
            out.append(table[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func nibble(_ scalar: Unicode.Scalar) -> UInt8? {
        switch scalar.value {
        case 0x30...0x39: return UInt8(scalar.value - 0x30)
        case 0x41...0x46: return UInt8(scalar.value - 0x41 + 10)
        case 0x61...0x66: return UInt8(scalar.value - 0x61 + 10)
        default: return nil
        }
    }
}
