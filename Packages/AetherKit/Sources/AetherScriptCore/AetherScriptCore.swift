import AetherFoundation

/// AetherScriptCore：ScriptRuntime 协议、脚本值类型、ScriptHostServices 协议、cron 表达式解析。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherScriptCoreModule {
    /// 模块名。
    public static let name = "AetherScriptCore"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherFoundationModule.name]
}
