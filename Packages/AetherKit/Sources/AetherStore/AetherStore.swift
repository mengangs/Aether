import AetherFoundation

/// AetherStore：流量统计、请求历史、日志簿、脚本存储的数据库访问（docs/11 §4）。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。
public enum AetherStoreModule {
    /// 模块名。
    public static let name = "AetherStore"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherFoundationModule.name]
}

extension AetherErrorCode {
    /// 数据库无法打开或迁移失败（docs/11 §9）。
    public static let stoDatabaseUnavailable: AetherErrorCode = "STO-002"
    /// 数据库读写失败（docs/11 §9）。
    public static let stoDatabaseFailed: AetherErrorCode = "STO-003"
}

/// 存储错误（docs/11 §9）。
public struct StoreError: AetherErrorProtocol, Equatable {
    public let code: AetherErrorCode
    public let debugDetails: String

    public init(_ code: AetherErrorCode, _ debugDetails: String) {
        self.code = code
        self.debugDetails = debugDetails
    }
}
