import AetherFoundation
import CBlake3

/// AetherOutbound：出站连接器与各代理协议、传输层（TLS、WebSocket、obfs）、测速。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。本类型只用于标识模块，随模块实现逐步被真实类型取代。
public enum AetherOutboundModule {
    /// 模块名。
    public static let name = "AetherOutbound"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherFoundationModule.name, "CBlake3"]
}
