import AetherFoundation
import NIOCore

/// 每个目标一条子关联的 UDP 关联（VLESS、VMess 的 UDP：一条连接只能发往一个目标，docs/06 §10）。
///
/// - 子关联按需建立，最多 `limit` 个（默认 32），超出时关闭最久未发送的一个；
/// - 建立期间的数据报在该目标的队列中等待，每个目标最多 `pendingLimit` 个（默认 32，同 docs/06 §10），
///   超出丢弃最旧的；
/// - 子关联建立失败或关闭后从表中移除，下一个数据报重新建立；
/// - 本关联关闭时关闭全部子关联。
/// 绑定到创建它的 EventLoop。
final class PerDestinationUDPAssociation: OutboundUDPAssociation, @unchecked Sendable {
    typealias Opener = (Destination) -> EventLoopFuture<any OutboundUDPAssociation>

    var onDatagram: ((ByteBuffer, Destination) -> Void)?
    var closeFuture: EventLoopFuture<Void> { closePromise.futureResult }
    /// 丢弃的数据报数（队列溢出、建立失败）。
    private(set) var dropped = 0

    private enum Entry {
        case opening(pending: [ByteBuffer])
        case open(any OutboundUDPAssociation)
    }

    private let eventLoop: any EventLoop
    private let limit: Int
    private let pendingLimit: Int
    private let open: Opener
    private let closePromise: EventLoopPromise<Void>
    private var entries: [Destination: Entry] = [:]
    /// 最近发送的顺序（最久未发送在前）。
    private var order: [Destination] = []
    private var closed = false

    init(eventLoop: any EventLoop, limit: Int = 32, pendingLimit: Int = 32, open: @escaping Opener) {
        self.eventLoop = eventLoop
        self.limit = limit
        self.pendingLimit = pendingLimit
        self.open = open
        closePromise = eventLoop.makePromise()
    }

    func send(_ payload: ByteBuffer, to destination: Destination) {
        eventLoop.preconditionInEventLoop()
        guard !closed else { return }
        touch(destination)
        switch entries[destination] {
        case .open(let association):
            association.send(payload, to: destination)
        case .opening(var pending):
            if pending.count >= pendingLimit {
                pending.removeFirst()
                dropped += 1
            }
            pending.append(payload)
            entries[destination] = .opening(pending: pending)
        case nil:
            if entries.count >= limit, let oldest = order.first(where: { $0 != destination }) {
                remove(oldest, close: true)
            }
            entries[destination] = .opening(pending: [payload])
            open(destination).hop(to: eventLoop).whenComplete { result in
                self.opened(destination, result)
            }
        }
    }

    private func opened(_ destination: Destination, _ result: Result<any OutboundUDPAssociation, any Error>) {
        guard case .opening(let pending) = entries[destination] else {
            // 建立期间被淘汰或本关联已关闭。
            if case .success(let association) = result { association.close() }
            return
        }
        switch result {
        case .failure:
            dropped += pending.count
            remove(destination, close: false)
        case .success(let association):
            guard !closed else {
                association.close()
                return
            }
            association.onDatagram = { [weak self] payload, source in
                self?.onDatagram?(payload, source)
            }
            association.closeFuture.whenComplete { _ in
                self.eventLoop.execute {
                    if case .open(let current) = self.entries[destination], current === association {
                        self.remove(destination, close: false)
                    }
                }
            }
            entries[destination] = .open(association)
            for payload in pending {
                association.send(payload, to: destination)
            }
        }
    }

    private func touch(_ destination: Destination) {
        if let index = order.firstIndex(of: destination) {
            order.remove(at: index)
        }
        order.append(destination)
    }

    private func remove(_ destination: Destination, close: Bool) {
        if close, case .open(let association) = entries[destination] {
            association.close()
        }
        entries[destination] = nil
        order.removeAll { $0 == destination }
    }

    func close() {
        guard !closed else { return }
        closed = true
        onDatagram = nil
        for case .open(let association) in entries.values {
            association.close()
        }
        entries.removeAll()
        order.removeAll()
        closePromise.succeed(())
    }
}
