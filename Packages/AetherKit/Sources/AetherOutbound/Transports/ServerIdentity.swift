import AetherFoundation
import NIOCore
import X509

/// TLS 服务器身份校验（docs/06 §8 TLS 行）：握手（只验证证书链）完成后，按与 NIOSSL 相同的规则比对叶子证书的
/// 主题备用名称——DNS 名（左起第一个标签可含一个通配符，IDNA 标签不参与通配）或与远端地址相同的 IP；
/// 证书没有可比对的备用名称时退回主题 CN。自己做这一步使各平台的主机名不匹配都报 `TLS-002`
/// （Apple 平台上系统信任评估会把它并入一般的链验证失败）。
enum ServerIdentity {
    /// `hostname` 为 nil（服务器地址为 IP 且不发 SNI）时只比对 IP 备用名称。
    static func matches(leafDER: [UInt8], hostname: String?, remoteAddress: SocketAddress?) -> Bool {
        guard let certificate = try? Certificate(derEncoded: leafDER) else { return false }
        let target = hostname.flatMap(normalize)
        let remoteIP = remoteAddress?.ipAddress.flatMap { IPAddress($0) }?.unmappedIPv4
        var sawName = false
        if let names = try? certificate.extensions.subjectAlternativeNames {
            for name in names {
                switch name {
                case .dnsName(let dnsName):
                    sawName = true
                    if let target, matchesDNSName(dnsName, target: target) { return true }
                case .ipAddress(let octets):
                    sawName = true
                    if let remoteIP, IPAddress(bytes: Array(octets.bytes))?.unmappedIPv4 == remoteIP { return true }
                default:
                    continue
                }
            }
        }
        guard !sawName, let target else { return false }
        for rdn in certificate.subject {
            for attribute in rdn where attribute.type == .RDNAttributeType.commonName {
                if let name = String(attribute.value), matchesDNSName(name, target: target) { return true }
            }
        }
        return false
    }

    /// 小写、去掉末尾的点；含 DNS 合法字符以外的字符时为 nil（无法匹配）。
    private static func normalize(_ name: String) -> String? {
        var value = name.lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        let valid = value.utf8.allSatisfy { byte in
            let letter = (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            let digit = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            return letter || digit || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
        }
        return valid && !value.isEmpty ? value : nil
    }

    static func matchesDNSName(_ pattern: String, target: String) -> Bool {
        var pattern = pattern.lowercased()
        if pattern.hasSuffix(".") { pattern.removeLast() }
        let patternLabels = pattern.split(separator: ".", omittingEmptySubsequences: false)
        let targetLabels = target.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = patternLabels.first, patternLabels.count == targetLabels.count else { return false }
        guard patternLabels.dropFirst().allSatisfy({ !$0.contains("*") }),
            patternLabels.dropFirst().elementsEqual(targetLabels.dropFirst())
        else { return false }
        guard let star = first.firstIndex(of: "*") else { return first == targetLabels[0] }
        let prefix = first[..<star]
        let suffix = first[first.index(after: star)...]
        let label = targetLabels[0]
        guard !suffix.contains("*"), !first.hasPrefix("xn--"), !label.hasPrefix("xn--"),
            label.count >= prefix.count + suffix.count
        else { return false }
        return label.hasPrefix(prefix) && label.hasSuffix(suffix)
    }
}
