import AetherEngine
import AetherFoundation
import Darwin
import Foundation
@preconcurrency import NetworkExtension

/// 备用桥接（docs/06 §4.1）：找不到 utun 描述符时，创建一对 `SOCK_DGRAM` 的 `socketpair`，`hevDescriptor` 交给 hev，
/// 另一端由本类在 `NEPacketTunnelFlow` 与 socket 之间搬运，按 utun 格式加上或去掉 4 字节协议族头。
///
/// - 从 socket 读：每次可读事件最多读 64 个包后批量 `writePackets`，单包缓冲 64 KiB + 4；
/// - 写入 socket 失败（缓冲满等）时丢弃该包并计数，不排队；
/// - 有额外开销，启用时由调用方写日志簿警告。🔬 需在真机上验证。
public final class PacketFlowBridge: @unchecked Sendable {
    /// 交给 hev 的一端。hev 退出后由 `close()` 关闭。
    public let hevDescriptor: Int32
    private let localDescriptor: Int32
    private let flow: NEPacketTunnelFlow
    private let queue = DispatchQueue(label: "aether.packet-flow-bridge")
    private let state = Locked(State())

    private struct State {
        var readSource: (any DispatchSourceRead)?
        var stopped = false
        var droppedPackets = 0
    }

    /// 丢弃的包数（无法识别的协议族、写入 socket 失败）。
    public var droppedPackets: Int { state.withLock { $0.droppedPackets } }

    public init(flow: NEPacketTunnelFlow) throws {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
            throw NetworkError(.netEngineNotReady, "socketpair failed: errno \(errno)")
        }
        var bufferSize: Int32 = 4 * 1024 * 1024
        for descriptor in descriptors {
            _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
            _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        }
        _ = fcntl(descriptors[1], F_SETFL, fcntl(descriptors[1], F_GETFL) | O_NONBLOCK)
        hevDescriptor = descriptors[0]
        localDescriptor = descriptors[1]
        self.flow = flow
    }

    /// 开始双向搬运。
    public func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: localDescriptor, queue: queue)
        source.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        state.withLock { $0.readSource = source }
        source.resume()
        readFromFlow()
    }

    private func readFromFlow() {
        flow.readPackets { [weak self] packets, protocols in
            guard let self, !self.state.withLock({ $0.stopped }) else { return }
            var dropped = 0
            for (index, packet) in packets.enumerated() {
                let family = index < protocols.count ? protocols[index].uint32Value : nil
                guard let frame = UTunFraming.wrap([UInt8](packet), family: family) else {
                    dropped += 1
                    continue
                }
                let sent = frame.withUnsafeBytes { send(self.localDescriptor, $0.baseAddress, $0.count, 0) }
                if sent < 0 {
                    dropped += 1
                }
            }
            if dropped > 0 {
                self.state.withLock { $0.droppedPackets += dropped }
            }
            self.readFromFlow()
        }
    }

    private func drainSocket() {
        var packets: [Data] = []
        var protocols: [NSNumber] = []
        var buffer = [UInt8](repeating: 0, count: 65_536 + 4)
        var dropped = 0
        while packets.count < 64 {
            let count = buffer.withUnsafeMutableBytes { recv(localDescriptor, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { break }
            guard let (packet, family) = UTunFraming.unwrap(Array(buffer[0..<count])) else {
                dropped += 1
                continue
            }
            packets.append(Data(packet))
            protocols.append(NSNumber(value: family))
        }
        if dropped > 0 {
            state.withLock { $0.droppedPackets += dropped }
        }
        if !packets.isEmpty {
            flow.writePackets(packets, withProtocols: protocols)
        }
    }

    /// 停止搬运并关闭两端描述符（在 hev 退出之后调用）。重复调用无副作用。
    public func close() {
        let (wasStopped, source) = state.withLock { state -> (Bool, (any DispatchSourceRead)?) in
            let result = (state.stopped, state.readSource)
            state.stopped = true
            state.readSource = nil
            return result
        }
        guard !wasStopped else { return }
        source?.cancel()
        Darwin.close(localDescriptor)
        Darwin.close(hevDescriptor)
    }
}
