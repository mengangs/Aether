import AetherDNS
import AetherHTTP
import AetherIPC
import AetherProfile
import AetherRules
import AetherStore

/// AetherEngine：入站、Router、流管理、策略组、统计、运行配置装配与热替换、IPC 命令处理。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherEngineModule {
    /// 模块名。
    public static let name = "AetherEngine"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [
        AetherDNSModule.name, AetherHTTPModule.name, AetherIPCModule.name, AetherProfileModule.name,
        AetherRulesModule.name, AetherStoreModule.name,
    ]
}
