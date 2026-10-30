import AetherFoundation
import AetherIPC
import Foundation
import NIOCore

/// 请求记录（docs/06 §12.2）：活动流在字典中，结束的流进入环形缓冲（默认 500，可设为 200–2000，溢出时丢弃最旧的）。
/// 绑定到数据面 EventLoop。
public final class RequestLog: @unchecked Sendable {
    public static let defaultCapacity = 500
    public static let capacityRange = 200...2000

    public let eventLoop: any EventLoop
    private let clock: @Sendable () -> Date
    private var active: [UInt64: RequestRecord] = [:]
    private var finished: [RequestRecord] = []
    private var finishedStart = 0
    public private(set) var capacity: Int
    /// 记录结束时回调（统计、请求历史落盘）。
    public var onFinish: ((RequestRecord) -> Void)?

    public init(
        eventLoop: any EventLoop, capacity: Int = RequestLog.defaultCapacity,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.eventLoop = eventLoop
        self.capacity = min(max(capacity, Self.capacityRange.lowerBound), Self.capacityRange.upperBound)
        self.clock = clock
    }

    public var now: Date { clock() }

    /// 开始一条记录。
    public func start(_ record: RequestRecord) {
        eventLoop.preconditionInEventLoop()
        active[record.id] = record
    }

    /// 修改活动记录（不存在时忽略）。
    public func update(_ id: FlowID, _ body: (inout RequestRecord) -> Void) {
        eventLoop.preconditionInEventLoop()
        guard var record = active[id.rawValue] else { return }
        body(&record)
        active[id.rawValue] = record
    }

    /// 结束一条记录：写入结束时间、状态与错误码，移入环形缓冲。
    public func finish(
        _ id: FlowID, error: (any AetherErrorProtocol)? = nil, _ body: (inout RequestRecord) -> Void = { _ in }
    ) {
        eventLoop.preconditionInEventLoop()
        guard var record = active.removeValue(forKey: id.rawValue) else { return }
        body(&record)
        record.endedAt = clock()
        if let error {
            record.state = .failed
            record.errorCode = error.code.rawValue
        } else if record.state == .active {
            record.state = .completed
        }
        append(record)
        onFinish?(record)
    }

    private func append(_ record: RequestRecord) {
        if finished.count < capacity {
            finished.append(record)
        } else {
            finished[finishedStart] = record
            finishedStart = (finishedStart + 1) % capacity
        }
    }

    /// 最近结束的记录，按 id 升序。
    public var recent: [RequestRecord] {
        eventLoop.preconditionInEventLoop()
        return Array(finished[finishedStart...] + finished[..<finishedStart])
    }

    /// 活动记录，按 id 升序。
    public var activeRecords: [RequestRecord] {
        eventLoop.preconditionInEventLoop()
        return active.values.sorted { $0.id < $1.id }
    }

    public func record(_ id: FlowID) -> RequestRecord? {
        eventLoop.preconditionInEventLoop()
        return active[id.rawValue] ?? finished.first { $0.id == id.rawValue }
    }

    /// 分页：`sinceID` 之后（不含）的记录，最多 `limit` 条（上限 200）。返回下一页游标（最后一条的 id）。
    public func page(kind: RequestListKind, sinceID: UInt64?, limit: Int) -> (records: [RequestRecord], next: UInt64?) {
        let source = kind == .active ? activeRecords : recent
        let filtered = source.filter { record in sinceID.map { record.id > $0 } ?? true }
        let page = Array(filtered.prefix(min(max(limit, 1), IPCProtocol.maxPageSize)))
        return (page, page.last?.id)
    }

    /// 调整容量（设置项）；缩小时丢弃最旧的记录。
    public func setCapacity(_ value: Int) {
        eventLoop.preconditionInEventLoop()
        let ordered = recent
        capacity = min(max(value, Self.capacityRange.lowerBound), Self.capacityRange.upperBound)
        finished = Array(ordered.suffix(capacity))
        finishedStart = 0
    }

    /// 内存压力：结束记录缩减到容量的 1/4（docs/02 §6）。
    public func shrinkForMemoryPressure() {
        eventLoop.preconditionInEventLoop()
        let ordered = recent
        finished = Array(ordered.suffix(max(1, capacity / 4)))
        finishedStart = 0
    }
}
