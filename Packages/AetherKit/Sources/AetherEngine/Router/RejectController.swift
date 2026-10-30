import AetherFoundation
import AetherHTTP
import NIOCore

/// 拒绝类策略（docs/06 §8.3）。
public enum RejectKind: String, Sendable, Hashable {
    case reject = "REJECT"
    case tinyGIF = "REJECT-TINYGIF"
    case drop = "REJECT-DROP"
    case noDrop = "REJECT-NO-DROP"
}

/// 拒绝策略的执行与自动升级保护（docs/06 §8.3）。绑定到数据面 EventLoop。
///
/// - 自动升级：同一主机 1 秒内被 `REJECT` 超过 10 次，之后 30 秒内对它的 `REJECT` 按 `REJECT-DROP` 处理
///   （`REJECT-NO-DROP` 不参与，`REJECT-TINYGIF` 不升级）；
/// - `REJECT-DROP`：保持连接不发送任何数据，对端关闭或 60 秒后关闭；同时保持的连接上限 256，超出按 `REJECT` 处理；
/// - 计数表最多记录 1,024 个主机，满时先清理过期窗口，仍满则清空（溢出只会让保护晚一点生效）。
public final class RejectController: @unchecked Sendable {
    public static let dropLimit = 256
    public static let dropHold = TimeAmount.seconds(60)
    static let stormThreshold = 10
    static let stormWindow = TimeAmount.seconds(1)
    static let upgradeDuration = TimeAmount.seconds(30)
    static let trackedHostLimit = 1024

    public let eventLoop: any EventLoop
    private var windows: [String: (start: NIODeadline, count: Int)] = [:]
    private var upgradedUntil: [String: NIODeadline] = [:]
    /// 当前保持中的 DROP 连接数。
    public private(set) var heldConnections = 0

    public init(eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    /// 计入一次拒绝并返回实际执行的种类（应用自动升级与 DROP 上限）。
    public func effectiveKind(_ kind: RejectKind, host: String?) -> RejectKind {
        eventLoop.preconditionInEventLoop()
        let now = eventLoop.now
        var effective = kind
        if kind == .reject, let host {
            if let until = upgradedUntil[host] {
                if now < until {
                    effective = .drop
                } else {
                    upgradedUntil[host] = nil
                }
            }
            record(host: host, now: now)
        }
        if effective == .drop, heldConnections >= Self.dropLimit {
            effective = .reject
        }
        return effective
    }

    private func record(host: String, now: NIODeadline) {
        if windows.count >= Self.trackedHostLimit, windows[host] == nil {
            windows = windows.filter { now - $0.value.start < Self.stormWindow }
            if windows.count >= Self.trackedHostLimit {
                windows.removeAll()
            }
            if upgradedUntil.count >= Self.trackedHostLimit {
                upgradedUntil = upgradedUntil.filter { now < $0.value }
            }
        }
        var window = windows[host] ?? (now, 0)
        if now - window.start >= Self.stormWindow {
            window = (now, 0)
        }
        window.count += 1
        windows[host] = window
        if window.count > Self.stormThreshold {
            upgradedUntil[host] = now + Self.upgradeDuration
        }
    }

    /// 对 TCP 流执行拒绝：`REJECT-DROP` 保持连接（读取并丢弃数据，对端关闭或到时后关闭），其余立即关闭。
    /// 调用前应已通过 `effectiveKind` 得到实际种类。
    public func rejectTCP(_ kind: RejectKind, channel: any Channel) {
        eventLoop.preconditionInEventLoop()
        guard kind == .drop else {
            channel.close(promise: nil)
            return
        }
        heldConnections += 1
        let timer = channel.eventLoop.scheduleTask(in: Self.dropHold) {
            channel.close(promise: nil)
        }
        channel.closeFuture.whenComplete { _ in
            timer.cancel()
            self.heldConnections -= 1
        }
        do {
            try channel.pipeline.syncOperations.addHandler(DiscardingHandler())
            try channel.syncOptions?.setOption(.autoRead, value: true)
        } catch {
            channel.close(promise: nil)
        }
    }

    /// 明文 HTTP 请求的拒绝响应（`show-error-page-for-reject` 决定 403 是否附说明页）。
    public func httpResponse(for kind: RejectKind, errorPage: Bool) -> HTTPRejectResponse {
        switch kind {
        case .reject, .noDrop: return .forbidden(errorPage: errorPage)
        case .tinyGIF: return .tinyGIF
        case .drop: return .drop(Self.dropHold)
        }
    }
}

/// 丢弃全部输入；读到 EOF 时关闭。
private final class DiscardingHandler: ChannelInboundHandler, Sendable {
    typealias InboundIn = NIOAny

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {}

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            context.close(promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        context.close(promise: nil)
    }
}
