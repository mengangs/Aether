import AetherFoundation

/// AetherDNS：DNS 报文编解码、上游客户端、缓存、Fake IP 池、Host 映射。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherDNSModule {
    /// 模块名。
    public static let name = "AetherDNS"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherFoundationModule.name]
}
