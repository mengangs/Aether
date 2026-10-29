import AetherTunnelSupport
import Foundation
@preconcurrency import NetworkExtension

/// Packet Tunnel 扩展入口（docs/06 §1）。本类只做转发：系统回调交给 `PacketTunnelCore`。
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private lazy var core = PacketTunnelCore(provider: self)

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        core.start(options: options, completionHandler: completionHandler)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        core.stop(reason: reason, completionHandler: completionHandler)
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)? = nil) {
        core.handleAppMessage(messageData, completionHandler: completionHandler)
    }
}
