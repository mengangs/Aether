import AetherCertificates
import AetherOutbound
import AetherRules
import AetherScriptCore

/// AetherHTTP：TLS 终止、HTTP 处理管线、重写、抓包、调用 ScriptRuntime。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherHTTPModule {
    /// 模块名。
    public static let name = "AetherHTTP"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [
        AetherCertificatesModule.name, AetherOutboundModule.name, AetherRulesModule.name, AetherScriptCoreModule.name,
    ]
}
