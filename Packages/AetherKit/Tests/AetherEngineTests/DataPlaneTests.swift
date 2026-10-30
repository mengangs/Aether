import AetherFoundation
import AetherOutbound
import AetherTestSupport
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing

@testable import AetherEngine

// MARK: - 测试中转：127.0.0.1 上的监听端口，每个连接 DIRECT 到目标并以胶水 Handler 转发

private final class TestRelay: Sendable {
    let server: LoopbackTCPServer
    let flows: FlowManager
    private let accepted: NIOLockedValueBox<[(id: FlowID, channel: any Channel)]>

    private init(
        server: LoopbackTCPServer, flows: FlowManager, accepted: NIOLockedValueBox<[(id: FlowID, channel: any Channel)]>
    ) {
        self.server = server
        self.flows = flows
        self.accepted = accepted
    }

    static func start(threads: EngineThreads, targetPort: Int, limits: FlowManager.Limits = .init()) async throws
        -> TestRelay
    {
        let loop = threads.eventLoop
        let flows = FlowManager(eventLoop: loop, limits: limits)
        let accepted = NIOLockedValueBox<[(id: FlowID, channel: any Channel)]>([])
        let server = try await LoopbackTCPServer.start(
            group: loop,
            childOptions: { ChannelTuning.configure($0).childChannelOption(.autoRead, value: false) },
            childInitializer: { child in
                child.eventLoop.makeCompletedFuture { () -> (FlowID, NIOLoopBound<FlowCounters>) in
                    let id = flows.allocateID()
                    let counters = FlowCounters()
                    try flows.register(id, inbound: child, counters: counters)
                    accepted.withLockedValue { $0.append((id, child)) }
                    return (id, NIOLoopBound(counters, eventLoop: child.eventLoop))
                }.flatMap { id, counters in
                    ChannelTuning.configure(ClientBootstrap(group: child.eventLoop))
                        .connect(host: "127.0.0.1", port: targetPort)
                        .flatMapThrowing { outbound in
                            flows.attach(id, channel: outbound)
                            _ = try FlowRelay.glue(inbound: child, outbound: outbound, counters: counters.value)
                        }
                }
            })
        return TestRelay(server: server, flows: flows, accepted: accepted)
    }

    var first: (id: FlowID, channel: any Channel)? {
        accepted.withLockedValue { $0.first }
    }

    /// 在 EventLoop 上读取某个流的计数。
    func counters(_ id: FlowID) async throws -> (up: UInt64, down: UInt64)? {
        let flows = self.flows
        return try await flows.eventLoop.submit {
            flows.counters(for: id).map { (up: $0.bytesUp, down: $0.bytesDown) }
        }.get()
    }
}

/// 测试数据：长度为素数的伪随机块循环重复，偏移错位或丢字节都会使比较失败。
private enum BulkPattern {
    static let block: [UInt8] = {
        var generator = SplitMix64(seed: 0xAE7E)
        return (0..<65521).map { _ in UInt8(truncatingIfNeeded: generator.next()) }
    }()

    /// 比较 `bytes` 是否等于从 `offset` 开始的期望内容。
    static func matches(_ bytes: UnsafeRawBufferPointer, at offset: Int) -> Bool {
        var position = 0
        var cursor = offset % block.count
        return block.withUnsafeBytes { expected in
            while position < bytes.count {
                let run = min(bytes.count - position, block.count - cursor)
                guard let lhs = bytes.baseAddress, let rhs = expected.baseAddress else { return false }
                if memcmp(lhs + position, rhs + cursor, run) != 0 { return false }
                position += run
                cursor = 0
            }
            return true
        }
    }
}

/// 连接建立后一次性写出 `total` 字节，之后保持连接。
private final class BulkSender: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer

    let total: Int

    init(total: Int) {
        self.total = total
    }

    func channelActive(context: ChannelHandlerContext) {
        var offset = 0
        let block = BulkPattern.block
        while offset < total {
            let start = offset % block.count
            let count = min(block.count - start, total - offset)
            context.write(NIOAny(context.channel.allocator.buffer(bytes: block[start..<(start + count)])), promise: nil)
            offset += count
        }
        context.flush()
        context.fireChannelActive()
    }
}

/// 只校验与计数、不保存内容的接收端。
private final class VerifyingReceiver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let state = NIOLockedValueBox<(count: Int, corrupt: Bool)>((0, false))

    var count: Int { state.withLockedValue { $0.count } }
    var corrupt: Bool { state.withLockedValue { $0.corrupt } }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        state.withLockedValue { state in
            let ok = buffer.withUnsafeReadableBytes { BulkPattern.matches($0, at: state.count) }
            if !ok {
                state.corrupt = true
            }
            state.count += buffer.readableBytes
        }
    }
}

/// 回显并在读到 EOF 后再写 "bye" 然后关闭（验证半关闭的两个方向）。
private final class EchoThenBye: ChannelInboundHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.writeAndFlush(data, promise: nil)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.inputClosed) = event as? ChannelEvent {
            let buffer = context.channel.allocator.buffer(string: "bye")
            context.writeAndFlush(wrapOutboundOut(buffer)).assumeIsolated().whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }
}

// MARK: - 真实 socket 上的转发

@Suite("Data plane relay")
struct DataPlaneRelayTests {
    @Test("Half-close travels both ways and bytes are counted")
    func halfClose() async throws {
        let threads = EngineThreads()
        let target = try await LoopbackTCPServer.start(group: threads.group) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(EchoThenBye())
            }
        }
        let relay = try await TestRelay.start(threads: threads, targetPort: target.port)
        let collector = CollectingHandler()
        let client = try await ClientBootstrap(group: threads.group)
            .channelOption(.allowRemoteHalfClosure, value: true)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
            }
            .connect(host: "127.0.0.1", port: relay.server.port).get()

        try await client.writeAndFlush(ByteBuffer(string: "hello"))
        #expect(await Poll.until { collector.bytes.count == 5 })
        try await client.close(mode: .output)
        #expect(await Poll.until { collector.isClosed })
        #expect(String(decoding: collector.bytes, as: UTF8.self) == "hellobye")

        let first = try #require(relay.first)
        // 流在两个方向都结束后自动注销。
        #expect(await Poll.until { (try? await relay.counters(first.id)) == nil })
        #expect(try await threads.eventLoop.submit { relay.flows.activeCount }.get() == 0)

        try await relay.server.close()
        try await target.close()
        try await threads.shutdown()
    }

    @Test("A slow consumer does not make the relay buffer more than one window")
    func slowConsumerBackpressure() async throws {
        let total = 24 << 20
        let threads = EngineThreads()
        let target = try await LoopbackTCPServer.start(group: threads.group) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(BulkSender(total: total))
            }
        }
        let relay = try await TestRelay.start(threads: threads, targetPort: target.port)
        let receiver = VerifyingReceiver()
        // 客户端先不读取：数据只能堆在内核缓冲与中转里（接收缓冲设小，减少内核吸收的量）。
        let client = try await ClientBootstrap(group: threads.group)
            .channelOption(.autoRead, value: false)
            .channelOption(.socketOption(.so_rcvbuf), value: 64 * 1024)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(receiver) }
            }
            .connect(host: "127.0.0.1", port: relay.server.port).get()

        #expect(await Poll.until { relay.first != nil })
        let first = try #require(relay.first)

        // 等中转停止读取（下行计数连续多次不再变化）。
        var last: UInt64 = 0
        var stableRounds = 0
        for _ in 0..<400 where stableRounds < 4 {
            try await Task.sleep(for: .milliseconds(50))
            let down = try await relay.counters(first.id)?.down ?? 0
            stableRounds = (down > 0 && down == last) ? stableRounds + 1 : 0
            last = down
        }
        #expect(stableRounds >= 4)

        // 中转在用户态缓冲的字节不超过「高水位 64 KiB + 一次读取 64 KiB」，且没有把源端数据全部读入。
        let buffered = try await first.channel.getOption(.bufferedWritableBytes).get()
        #expect(buffered <= 128 * 1024)
        #expect(last < UInt64(total))

        // 放开读取：全部数据按序、完整到达。
        try await client.setOption(.autoRead, value: true).get()
        client.read()
        #expect(await Poll.until(timeout: .seconds(60)) { receiver.count == total })
        #expect(!receiver.corrupt)
        let counted = try await relay.counters(first.id)
        #expect(counted?.down == UInt64(total))

        try await client.close()
        try await relay.server.close()
        try await target.close()
        try await threads.shutdown()
    }

    @Test("Flows over the concurrency limit are refused with NET-040")
    func concurrencyLimit() async throws {
        let threads = EngineThreads()
        let target = try await LoopbackTCPServer.start(group: threads.group) { channel in
            channel.eventLoop.makeSucceededVoidFuture()
        }
        var limits = FlowManager.Limits()
        limits.maxConcurrentFlows = 2
        limits.warningThreshold = 1
        let relay = try await TestRelay.start(threads: threads, targetPort: target.port, limits: limits)
        let events = NIOLockedValueBox<[FlowManager.Event]>([])
        try await threads.eventLoop.submit {
            relay.flows.onEvent = { event in events.withLockedValue { $0.append(event) } }
        }.get()

        var clients: [any Channel] = []
        for _ in 0..<3 {
            let collector = CollectingHandler()
            let client = try await ClientBootstrap(group: threads.group)
                .channelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(collector) }
                }
                .connect(host: "127.0.0.1", port: relay.server.port).get()
            clients.append(client)
            if clients.count == 3 {
                // 第三个连接在准入时被拒绝：中转直接关闭它。
                #expect(await Poll.until { collector.isClosed })
            }
        }
        #expect(try await threads.eventLoop.submit { relay.flows.activeCount }.get() == 2)
        #expect(events.withLockedValue { $0 }.contains(.warningThresholdExceeded(activeFlows: 2)))
        #expect(events.withLockedValue { $0 }.contains(.limitReached(activeFlows: 2)))

        // 停止：全部流在宽限期内关闭。
        try await threads.eventLoop.flatSubmit { relay.flows.closeAll(grace: .milliseconds(200)) }.get()
        #expect(try await threads.eventLoop.submit { relay.flows.activeCount }.get() == 0)

        for client in clients { try? await client.close() }
        try await relay.server.close()
        try await target.close()
        try await threads.shutdown()
    }
}

// MARK: - EmbeddedEventLoop 上的确定性测试

/// 统计经过的 `read()` 请求（放在管线最靠近 head 的位置）。
private final class ReadProbe: ChannelOutboundHandler {
    typealias OutboundIn = NIOAny

    var reads = 0

    func read(context: ChannelHandlerContext) {
        reads += 1
        context.read()
    }
}

@Suite("Data plane (deterministic)")
struct DataPlaneDeterministicTests {
    private func makePair(loop: EmbeddedEventLoop, idle: TimeAmount? = nil) throws -> (
        inbound: EmbeddedChannel, outbound: EmbeddedChannel, probe: ReadProbe, counters: FlowCounters
    ) {
        let inbound = EmbeddedChannel(loop: loop)
        let outbound = EmbeddedChannel(loop: loop)
        try inbound.connect(to: SocketAddress(ipAddress: "192.0.2.1", port: 1)).wait()
        try outbound.connect(to: SocketAddress(ipAddress: "192.0.2.2", port: 2)).wait()
        let probe = ReadProbe()
        try inbound.pipeline.syncOperations.addHandler(probe)
        let counters = FlowCounters()
        _ = try FlowRelay.glue(inbound: inbound, outbound: outbound, counters: counters, idleTimeout: idle)
        return (inbound, outbound, probe, counters)
    }

    @Test("Reads stop while the peer is not writable and resume afterwards")
    func backpressureStopsReads() throws {
        let loop = EmbeddedEventLoop()
        let pair = try makePair(loop: loop)
        let readsBefore = pair.probe.reads

        pair.outbound.isWritable = false
        pair.outbound.pipeline.fireChannelWritabilityChanged()
        pair.inbound.read()
        #expect(pair.probe.reads == readsBefore)

        pair.outbound.isWritable = true
        pair.outbound.pipeline.fireChannelWritabilityChanged()
        #expect(pair.probe.reads == readsBefore + 1)
    }

    @Test("Bytes are forwarded unchanged and counted per direction")
    func forwardsAndCounts() throws {
        let loop = EmbeddedEventLoop()
        let pair = try makePair(loop: loop)
        try pair.inbound.writeInbound(ByteBuffer(string: "GET / HTTP/1.1\r\n\r\n"))
        try pair.outbound.writeInbound(ByteBuffer(string: "HTTP/1.1 204 No Content\r\n\r\n"))
        #expect(try pair.outbound.readOutbound(as: ByteBuffer.self) == ByteBuffer(string: "GET / HTTP/1.1\r\n\r\n"))
        #expect(
            try pair.inbound.readOutbound(as: ByteBuffer.self) == ByteBuffer(string: "HTTP/1.1 204 No Content\r\n\r\n"))
        #expect(pair.counters.bytesUp == 18)
        #expect(pair.counters.bytesDown == 27)
        #expect(pair.counters.firstDownAt != nil)
    }

    @Test("Initial upload bytes (sniffed) are written first")
    func initialUpload() throws {
        let loop = EmbeddedEventLoop()
        let inbound = EmbeddedChannel(loop: loop)
        let outbound = EmbeddedChannel(loop: loop)
        let counters = FlowCounters()
        _ = try FlowRelay.glue(
            inbound: inbound, outbound: outbound, counters: counters, initialUpload: ByteBuffer(string: "peek"),
            idleTimeout: nil)
        try inbound.writeInbound(ByteBuffer(string: "rest"))
        #expect(try outbound.readOutbound(as: ByteBuffer.self) == ByteBuffer(string: "peek"))
        #expect(try outbound.readOutbound(as: ByteBuffer.self) == ByteBuffer(string: "rest"))
        #expect(counters.bytesUp == 8)
    }

    @Test("Closing one side closes the other")
    func closePropagates() throws {
        let loop = EmbeddedEventLoop()
        let pair = try makePair(loop: loop)
        try pair.outbound.close().wait()
        loop.run()
        #expect(!pair.inbound.isActive)
    }

    @Test("Flows idle in both directions are closed after the idle timeout")
    func idleTimeout() throws {
        func trace(_ message: String) {
            FileHandle.standardError.write(Data("TRACE idleTimeout: \(message)\n".utf8))
        }
        let loop = EmbeddedEventLoop()
        trace("loop.now=\(loop.now) existential.now=\((loop as any EventLoop).now)")
        let pair = try makePair(loop: loop, idle: .seconds(300))
        trace("pair ready")
        loop.advanceTime(by: .seconds(200))
        trace("advanced 200, now=\(loop.now)")
        try pair.inbound.writeInbound(ByteBuffer(string: "x"))
        trace("wrote inbound")
        loop.advanceTime(by: .seconds(200))
        trace("advanced 400, active=\(pair.inbound.isActive)")
        #expect(pair.inbound.isActive)
        loop.advanceTime(by: .seconds(101))
        trace("advanced 501, active=\(pair.inbound.isActive)")
        #expect(!pair.inbound.isActive)
        #expect(!pair.outbound.isActive)
    }

    @Test("Memory pressure refuses new flows with NET-041 until it expires")
    func memoryPressure() throws {
        let loop = EmbeddedEventLoop()
        let flows = FlowManager(eventLoop: loop)
        let start = NIODeadline.uptimeNanoseconds(1_000_000_000)
        flows.rejectNewFlows(for: .seconds(10), now: start)
        #expect(throws: NetworkError(.netMemoryPressure, "Rejecting new flows under critical memory pressure")) {
            try flows.checkAdmission(now: start + .seconds(5))
        }
        try flows.checkAdmission(now: start + .seconds(11))
    }

    @Test("Flow IDs increase monotonically")
    func flowIDs() {
        let loop = EmbeddedEventLoop()
        let flows = FlowManager(eventLoop: loop)
        let ids = (0..<5).map { _ in flows.allocateID() }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == 5)
    }

    @Test("closeAll half-closes, then forces closed after the grace period")
    func closeAllForces() throws {
        let loop = EmbeddedEventLoop()
        let flows = FlowManager(eventLoop: loop)
        let channel = EmbeddedChannel(loop: loop)
        try channel.connect(to: SocketAddress(ipAddress: "192.0.2.1", port: 80)).wait()
        try flows.register(flows.allocateID(), inbound: channel, counters: FlowCounters())
        #expect(flows.activeCount == 1)
        let done = flows.closeAll(grace: .seconds(1))
        loop.advanceTime(by: .seconds(1))
        try done.wait()
        #expect(flows.activeCount == 0)
    }
}
