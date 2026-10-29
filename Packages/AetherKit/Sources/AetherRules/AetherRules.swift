import AetherFoundation

/// AetherRules：规则编译与匹配、规则集与域名集、MMDB 读取器。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherRulesModule {
    /// 模块名。
    public static let name = "AetherRules"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherFoundationModule.name]
}
