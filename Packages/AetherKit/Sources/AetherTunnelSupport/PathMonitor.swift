import AetherFoundation
import AetherRules
import Foundation
import Network
@preconcurrency import NetworkExtension

/// 网络路径监控（docs/06 §11）：`NWPathMonitor` 生成 `NetworkSnapshot`；Wi-Fi 下用 `NEHotspotNetwork.fetchCurrent`
/// 读取 SSID / BSSID（需要 `wifi-info` 能力，缺少时为 nil，按"未知网络"处理）。接口类型、SSID、IPv4 / IPv6 可用性之一
/// 变化时网络修订号加一并回调 `onChange`。🔬 需在真机上验证隧道进程中的路径反映的是物理网络。
public final class PathMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "aether.path-monitor")
    private let state = Locked(NetworkSnapshot())
    private let changeHandler: (@Sendable (NetworkSnapshot) -> Void)?

    /// - Parameter onChange: 网络环境变化（修订号已加一）时在监控队列上调用。
    public init(onChange: (@Sendable (NetworkSnapshot) -> Void)? = nil) {
        changeHandler = onChange
    }

    /// 当前快照。
    public var current: NetworkSnapshot { state.current }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(path)
        }
        monitor.start(queue: queue)
    }

    public func cancel() {
        monitor.cancel()
    }

    /// 唤醒后网络修订号加一并回调（docs/06 §2.5）。
    public func bumpRevision() {
        let next = state.withLock { current -> NetworkSnapshot in
            current.revision += 1
            return current
        }
        changeHandler?(next)
    }

    private func update(_ path: NWPath) {
        let interface: SubnetCondition.InterfaceType? =
            if path.usesInterfaceType(.wifi) {
                .wifi
            } else if path.usesInterfaceType(.cellular) {
                .cellular
            } else if path.usesInterfaceType(.wiredEthernet) {
                .wired
            } else {
                nil
            }
        let snapshot = NetworkSnapshot(
            interfaceType: interface, isSatisfied: path.status == .satisfied, supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6, isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        guard interface == .wifi else {
            apply(snapshot)
            return
        }
        Self.fetchWiFi { [weak self] ssid, bssid in
            guard let self else { return }
            var withWiFi = snapshot
            withWiFi.ssid = ssid
            withWiFi.bssid = bssid
            let update = withWiFi
            self.queue.async { self.apply(update) }
        }
    }

    private func apply(_ snapshot: NetworkSnapshot) {
        let (next, changed) = state.withLock { current -> (NetworkSnapshot, Bool) in
            let result = Self.next(snapshot, after: current)
            current = result.snapshot
            return result
        }
        if changed {
            changeHandler?(next)
        }
    }

    /// 新快照沿用上一个的修订号；网络环境变化时加一。
    static func next(_ snapshot: NetworkSnapshot, after previous: NetworkSnapshot) -> (
        snapshot: NetworkSnapshot, changed: Bool
    ) {
        var next = snapshot
        let changed = snapshot.differsInEnvironment(from: previous)
        next.revision = previous.revision + (changed ? 1 : 0)
        return (next, changed)
    }

    private static func fetchWiFi(completion: @escaping @Sendable (String?, String?) -> Void) {
        #if os(iOS)
            NEHotspotNetwork.fetchCurrent { network in
                completion(network?.ssid, network?.bssid)
            }
        #else
            completion(nil, nil)
        #endif
    }
}
