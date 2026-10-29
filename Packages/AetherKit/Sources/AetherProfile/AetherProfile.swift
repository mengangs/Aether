import AetherFoundation

/// AetherProfile：配置的无损解析、类型化模型、模块叠加、校验与诊断、订阅与节点格式导入。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherProfileModule {
    /// 模块名。
    public static let name = "AetherProfile"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherFoundationModule.name]
}
