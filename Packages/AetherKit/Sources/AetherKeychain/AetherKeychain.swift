import AetherFoundation
import AetherIPC

/// AetherKeychain：Keychain 访问（访问组探测；M5 起存放 MitM CA 私钥），App 与隧道共用（仅 Apple 平台）。
///
/// 模块边界与依赖方向见 docs/02-architecture.md §3。
public enum AetherKeychainModule {
    /// 模块名。
    public static let name = "AetherKeychain"
    /// 本模块直接依赖的 AetherKit 模块。
    public static let dependencies: [String] = [AetherFoundationModule.name, AetherIPCModule.name]
}
