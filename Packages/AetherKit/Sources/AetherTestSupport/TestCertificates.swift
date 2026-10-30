import Crypto
import Foundation
import X509

/// 测试时临时生成的 CA 与服务器证书（P-256）。仓库中不保存任何私钥（CLAUDE.md），每次测试运行重新生成。
public struct TestCertificates: Sendable {
    /// CA 证书（PEM），作为测试中的信任根。
    public let caPEM: String
    /// 服务器证书（DER）。
    public let leafDER: [UInt8]
    /// 服务器证书（PEM）。
    public let leafPEM: String
    /// 服务器私钥（PEM，PKCS#8）。
    public let leafKeyPEM: String

    /// 生成由新 CA 签发、主题备用名称为 `dnsNames` 的服务器证书，有效期为当前时间前后一天。
    public static func make(dnsNames: [String], commonName: String = "Aether Test Server") throws -> TestCertificates {
        let caKey = P256.Signing.PrivateKey()
        let caName = try DistinguishedName { CommonName("Aether Test CA") }
        let now = Date()
        let ca = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(caKey.publicKey),
            notValidBefore: now - 86_400,
            notValidAfter: now + 86_400,
            issuer: caName,
            subject: caName,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
                Critical(KeyUsage(keyCertSign: true, cRLSign: true))
            },
            issuerPrivateKey: .init(caKey)
        )
        let leafKey = P256.Signing.PrivateKey()
        let leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: .init(leafKey.publicKey),
            notValidBefore: now - 86_400,
            notValidAfter: now + 86_400,
            issuer: caName,
            subject: try DistinguishedName { CommonName(commonName) },
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: try Certificate.Extensions {
                SubjectAlternativeNames(dnsNames.map { .dnsName($0) })
                try ExtendedKeyUsage([.serverAuth])
                Critical(KeyUsage(digitalSignature: true))
            },
            issuerPrivateKey: .init(caKey)
        )
        let leafDocument = try leaf.serializeAsPEM()
        return TestCertificates(
            caPEM: try ca.serializeAsPEM().pemString,
            leafDER: leafDocument.derBytes,
            leafPEM: leafDocument.pemString,
            leafKeyPEM: leafKey.pemRepresentation
        )
    }
}
