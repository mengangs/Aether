/// AetherFoundation：基础类型：IPAddress、CIDR、Endpoint、Hostname、LRU、错误码、日志工具、字节工具。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherFoundationModule {
    /// 模块名。
    public static let name = "AetherFoundation"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = []
}
