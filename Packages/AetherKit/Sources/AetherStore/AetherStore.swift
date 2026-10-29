import AetherFoundation

/// AetherStore：流量统计、请求历史、日志簿、脚本存储的数据库访问。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherStoreModule {
    /// 模块名。
    public static let name = "AetherStore"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherFoundationModule.name]
}
