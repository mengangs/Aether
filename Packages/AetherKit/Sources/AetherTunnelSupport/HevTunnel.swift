import AetherEngine
import AetherFoundation
import CHevSocks5Tunnel
import Foundation

/// hev-socks5-tunnel 的运行（docs/06 §4.2）：在专用线程（栈 512 KiB）上以内存中的 YAML 启动，
/// `hev_socks5_tunnel_main_from_str` 返回即视为退出。
///
/// hev 是进程内单例（全局状态），同一时刻只能运行一个 `HevTunnel`。非停止流程中的退出由调用方视为致命错误
/// （记录日志簿并 `cancelTunnelWithError`，M2-10）。
public final class HevTunnel: Sendable {
    /// `hev_socks5_tunnel_stats` 的收发统计（诊断页）。
    public struct Statistics: Sendable, Equatable {
        public var txPackets: Int
        public var txBytes: Int
        public var rxPackets: Int
        public var rxBytes: Int
    }

    public let configuration: HevConfiguration
    public let descriptor: Int32
    private let state = Locked(State())

    private struct State {
        var started = false
        var stopping = false
    }

    public init(configuration: HevConfiguration, descriptor: Int32) {
        self.configuration = configuration
        self.descriptor = descriptor
    }

    /// 在专用线程上启动 hev。`onExit` 在 hev 返回时于该线程调用一次：参数为返回码与是否由 `stop()` 引起。
    public func start(onExit: @escaping @Sendable (_ code: Int32, _ expected: Bool) -> Void) {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            return true
        }
        guard shouldStart else { return }
        let bytes = Array(configuration.yaml.utf8)
        let descriptor = self.descriptor
        let state = self.state
        let thread = Thread {
            let code = bytes.withUnsafeBufferPointer { buffer in
                hev_socks5_tunnel_main_from_str(buffer.baseAddress, UInt32(buffer.count), descriptor)
            }
            onExit(code, state.withLock { $0.stopping })
        }
        thread.name = "hev-socks5-tunnel"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    /// 请求 hev 退出（返回后 `onExit` 的 `expected` 为 true）。重复调用无副作用。
    public func stop() {
        let shouldQuit = state.withLock { state -> Bool in
            guard state.started, !state.stopping else { return false }
            state.stopping = true
            return true
        }
        if shouldQuit {
            hev_socks5_tunnel_quit()
        }
    }

    /// 当前的收发统计。
    public static var statistics: Statistics {
        var txPackets = 0
        var txBytes = 0
        var rxPackets = 0
        var rxBytes = 0
        hev_socks5_tunnel_stats(&txPackets, &txBytes, &rxPackets, &rxBytes)
        return Statistics(txPackets: txPackets, txBytes: txBytes, rxPackets: rxPackets, rxBytes: rxBytes)
    }
}
