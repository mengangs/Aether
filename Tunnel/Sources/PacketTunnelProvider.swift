import Foundation
@preconcurrency import NetworkExtension

/// Packet Tunnel 扩展入口（docs/06 §1）。本类只做转发：把系统回调交给 EngineLifecycle，
/// 把 App 消息交给 IPC 分发器。M0-07 实现最小闭环，M2-10 实现完整生命周期。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        completionHandler(
            NSError(
                domain: "Aether.Tunnel",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Tunnel is not implemented yet (M0-07)."]
            )
        )
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
