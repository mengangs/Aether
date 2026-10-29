import AetherFoundation

/// AetherCertificates：MitM 的 CA 生成、叶子证书签发、.mobileconfig 生成、CA 备份格式加解密。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherCertificatesModule {
    /// 模块名。
    public static let name = "AetherCertificates"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherFoundationModule.name]
}
