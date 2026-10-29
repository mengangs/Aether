import AetherScriptCore

/// AetherScript：ScriptRuntime 的 JavaScriptCore 实现与 JS API 桥接（仅 Apple 平台）。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherScriptModule {
    /// 模块名。
    public static let name = "AetherScript"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherScriptCoreModule.name]
}
