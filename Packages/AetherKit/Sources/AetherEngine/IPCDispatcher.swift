import AetherFoundation
import AetherIPC
import Foundation

/// 隧道侧 IPC 分发器（docs/10 §2.1）：解码请求、校验版本、调用处理函数、编码响应。
///
/// 任何输入都不会使其崩溃：无法解码返回 `IPC-003`，版本不一致返回 `IPC-002`，
/// 响应过大返回 `IPC-005`。处理函数在控制面执行。
public struct IPCDispatcher: Sendable {
    public typealias Handler = @Sendable (IPCCommand) async throws -> IPCPayload

    private let handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// 处理一条来自 App 的消息，返回编码后的响应。
    public func handle(_ message: Data) async -> Data {
        guard let envelope = IPCCodec.envelope(of: message) else {
            return Self.encode(
                IPCResponse(
                    id: IPCResponse.unknownRequestID,
                    outcome: .failure(IPCError(code: .ipcUndecodable, message: "Message is not an IPC request"))
                )
            )
        }
        guard envelope.version == IPCProtocol.version else {
            return Self.encode(
                IPCResponse(
                    id: envelope.id,
                    outcome: .failure(
                        IPCError(
                            code: .ipcVersionMismatch,
                            message: "Tunnel speaks IPC version \(IPCProtocol.version), app sent \(envelope.version)",
                            details: ["tunnelVersion": "\(IPCProtocol.version)", "appVersion": "\(envelope.version)"]
                        )
                    )
                )
            )
        }
        let request: IPCRequest
        do {
            request = try IPCCodec.decode(IPCRequest.self, from: message)
        } catch {
            return Self.encode(
                IPCResponse(
                    id: envelope.id,
                    outcome: .failure(IPCError(code: .ipcUndecodable, message: "Cannot decode request: \(error)"))
                )
            )
        }
        let outcome: IPCOutcome
        do {
            outcome = .success(try await handler(request.command))
        } catch {
            outcome = .failure(IPCError(error))
        }
        return Self.encode(IPCResponse(id: request.id, outcome: outcome))
    }

    /// 编码响应；负载过大时改为返回 `IPC-005`（该响应本身很小，一定能编码）。
    static func encode(_ response: IPCResponse) -> Data {
        do {
            return try IPCCodec.encode(response)
        } catch {
            let fallback = IPCResponse(id: response.id, outcome: .failure(IPCError(error)))
            return (try? IPCCodec.encode(fallback)) ?? Data()
        }
    }
}
