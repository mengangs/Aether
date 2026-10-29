import AetherFoundation

/// AetherIPC：App 与隧道之间的消息类型、AppEnvironment、共享路径、状态快照模型、Darwin 通知名。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherIPCModule {
    /// 模块名。
    public static let name = "AetherIPC"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherFoundationModule.name]
}
