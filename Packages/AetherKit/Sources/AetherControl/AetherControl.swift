import AetherIPC

/// AetherControl：App 侧隧道管理（TunnelController）、IPC 客户端（TunnelClient）、状态观察（仅 Apple 平台）。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherControlModule {
    /// 模块名。
    public static let name = "AetherControl"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherIPCModule.name]
}
