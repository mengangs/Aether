import AetherFoundation
import Foundation

/// IPC 传输：把一条请求送到隧道并取回响应。App 侧由 `AetherControl` 基于 `NETunnelProviderSession` 实现，测试用假实现。
public protocol IPCTransport: Sendable {
    /// 发送一条消息。
    /// - Returns: 隧道的响应；隧道没有回复时为 nil。
    /// - Throws: 隧道未运行时抛 `IPCError.tunnelNotRunning`（`IPC-001`）；任务取消时抛 `CancellationError`。
    func send(_ message: Data) async throws -> Data?
}

/// App 侧的 IPC 客户端核心（docs/10 §2.1）：编码请求、超时、校验响应。
/// `AetherControl` 的 `TunnelClient` 在它之上提供类型安全的方法。
public actor IPCClient {
    private let transport: any IPCTransport
    private let timeout: Duration
    private let clock: any Clock<Duration>

    public init(
        transport: any IPCTransport,
        timeout: Duration = IPCProtocol.defaultTimeout,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.transport = transport
        self.timeout = timeout
        self.clock = clock
    }

    /// 发送命令并返回负载。
    /// - Throws: 总是 `IPCError`：未运行 `IPC-001`、版本不一致 `IPC-002`、无法解码或无回复 `IPC-003`、
    ///   超时 `IPC-004`、负载过大 `IPC-005`，以及隧道返回的错误。
    public func send(_ command: IPCCommand) async throws -> IPCPayload {
        let request = IPCRequest(command: command)
        let data: Data
        do {
            data = try IPCCodec.encode(request)
        } catch {
            throw IPCError(error)
        }
        let reply = try await sendWithTimeout(data)
        guard let reply else { throw IPCError.noReply }
        let response: IPCResponse
        do {
            response = try IPCCodec.decode(IPCResponse.self, from: reply)
        } catch {
            if let envelope = IPCCodec.envelope(of: reply), envelope.version != IPCProtocol.version {
                throw IPCError(
                    code: .ipcVersionMismatch,
                    message: "Tunnel speaks IPC version \(envelope.version), app speaks \(IPCProtocol.version)"
                )
            }
            throw IPCError(code: .ipcUndecodable, message: "Cannot decode response: \(error)")
        }
        guard response.version == IPCProtocol.version else {
            throw IPCError(
                code: .ipcVersionMismatch,
                message: "Tunnel speaks IPC version \(response.version), app speaks \(IPCProtocol.version)"
            )
        }
        switch response.outcome {
        case .success(let payload):
            return payload
        case .failure(let error):
            throw error
        }
    }

    /// `getStatus`。
    public func status() async throws -> TunnelStatus {
        guard case .status(let status) = try await send(.getStatus) else {
            throw IPCError(code: .ipcUndecodable, message: "getStatus returned an unexpected payload")
        }
        return status
    }

    private func sendWithTimeout(_ data: Data) async throws -> Data? {
        let transport = self.transport
        let timeout = self.timeout
        let clock = self.clock
        do {
            return try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask {
                    try await transport.send(data)
                }
                group.addTask {
                    try await clock.sleep(for: timeout)
                    throw IPCError.timeout
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw IPCError.noReply
                }
                return first
            }
        } catch let error as IPCError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IPCError(error)
        }
    }
}
