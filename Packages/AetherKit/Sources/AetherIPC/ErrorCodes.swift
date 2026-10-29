import AetherFoundation

// IPC 与运行环境错误码（docs/10 §2.3）以及共享存储错误码（docs/11 §9）。

extension AetherErrorCode {
    /// 隧道未运行或会话不可用。
    public static let ipcTunnelNotRunning: AetherErrorCode = "IPC-001"
    /// 协议版本不一致。
    public static let ipcVersionMismatch: AetherErrorCode = "IPC-002"
    /// 消息无法解码。
    public static let ipcUndecodable: AetherErrorCode = "IPC-003"
    /// 超时。
    public static let ipcTimeout: AetherErrorCode = "IPC-004"
    /// 负载过大。
    public static let ipcPayloadTooLarge: AetherErrorCode = "IPC-005"
    /// 没有可用配置（Active Bundle 不存在）。
    public static let ipcNoActiveBundle: AetherErrorCode = "IPC-010"
    /// 参数无效。
    public static let ipcInvalidArgument: AetherErrorCode = "IPC-011"
    /// 当前状态不允许该操作。
    public static let ipcInvalidState: AetherErrorCode = "IPC-012"
    /// Info.plist 缺少标识符键或值无效（AppEnvironment）。
    public static let ipcInvalidEnvironment: AetherErrorCode = "IPC-020"

    /// App Group 容器不可用。
    public static let stoAppGroupUnavailable: AetherErrorCode = "STO-001"
}
