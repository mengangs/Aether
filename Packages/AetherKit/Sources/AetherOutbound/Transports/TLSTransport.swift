import AetherFoundation
import Crypto
import NIOConcurrencyHelpers
import NIOCore
import NIOSSL
import NIOTLS

/// 到代理服务器的 TLS 参数（docs/06 §8.5）。
public struct TLSClientOptions: Sendable, Hashable {
    public enum ServerName: Sendable, Hashable {
        /// 使用服务器地址（为 IP 时不发送 SNI）。
        case server
        case custom(String)
        /// `sni=off`。
        case disabled
    }

    public var serverName = ServerName.server
    /// `skip-cert-verify`：不验证证书链与主机名。
    public var skipCertificateVerification = false
    /// `server-cert-fingerprint-sha256`：只比对叶子证书 DER 的 SHA-256，不做链验证。
    public var certificateFingerprintSHA256: [UInt8]?
    public var alpn: [String] = []
    /// 额外信任的根证书（PEM），只用于测试；为空时使用系统信任根（Apple 平台走系统信任评估）。
    public var additionalTrustRootsPEM: [String] = []

    public init() {}

    /// 最终发送的 SNI；为 nil 表示不发送。
    func effectiveServerName(serverHost: String) -> String? {
        switch serverName {
        case .disabled: return nil
        case .custom(let name): return name
        case .server: return IPAddress(serverHost) == nil ? serverHost : nil
        }
    }
}

/// TLS 错误（docs/06 §15）。作为 `NET-033` 的细分出现在请求记录与日志中。
public struct TLSError: AetherErrorProtocol, Hashable {
    public let code: AetherErrorCode
    public let details: String

    public init(_ code: AetherErrorCode, _ details: String) {
        self.code = code
        self.details = details
    }

    public var debugDetails: String { details }
}

extension AetherErrorCode {
    /// 证书验证失败。
    public static let tlsCertificateInvalid: AetherErrorCode = "TLS-001"
    /// 主机名不匹配。
    public static let tlsHostnameMismatch: AetherErrorCode = "TLS-002"
    /// 证书指纹不匹配。
    public static let tlsFingerprintMismatch: AetherErrorCode = "TLS-003"
    /// 协议版本或算法协商失败。
    public static let tlsNegotiationFailed: AetherErrorCode = "TLS-004"
    /// 握手超时。
    public static let tlsHandshakeTimeout: AetherErrorCode = "TLS-005"
}

/// TLS 传输（swift-nio-ssl 客户端）：最低 TLS 1.2；同一组参数共享一个 `NIOSSLContext`（docs/02 §6）。
public enum TLSTransport {
    /// 共享的上下文缓存，按参数（不含 SNI）分组；最多 32 个，溢出时清空重建。
    private static let contexts = NIOLockedValueBox<[ContextKey: NIOSSLContext]>([:])
    static let contextLimit = 32

    private enum Verification: Hashable {
        case full
        case none
        /// 只比对叶子证书指纹：链验证由自定义回调替代，不做主机名验证。
        case pinned
    }

    private struct ContextKey: Hashable {
        var verification: Verification
        var alpn: [String]
        var roots: [String]
    }

    static func context(for options: TLSClientOptions) throws -> NIOSSLContext {
        let verification: Verification =
            options.certificateFingerprintSHA256 != nil ? .pinned : options.skipCertificateVerification ? .none : .full
        let key = ContextKey(verification: verification, alpn: options.alpn, roots: options.additionalTrustRootsPEM)
        return try contexts.withLockedValue { cache in
            if let existing = cache[key] {
                return existing
            }
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.minimumTLSVersion = .tlsv12
            // 关闭时等待对端 close_notify 的上限（默认 5 秒）：停止隧道时全部流在 1 秒宽限期后强制关闭（06 §2.3）。
            configuration.shutdownTimeout = .seconds(1)
            configuration.applicationProtocols = options.alpn
            switch verification {
            case .none:
                configuration.certificateVerification = .none
            case .pinned:
                // 自定义回调只在验证开启时才会被调用（NIOSSL 在 `.none` 时直接跳过）。
                configuration.certificateVerification = .noHostnameVerification
            case .full:
                configuration.certificateVerification = .fullVerification
            }
            if verification == .full, !options.additionalTrustRootsPEM.isEmpty {
                let certificates = try options.additionalTrustRootsPEM.flatMap {
                    try NIOSSLCertificate.fromPEMBytes(Array($0.utf8))
                }
                configuration.additionalTrustRoots = [.certificates(certificates)]
            }
            let context = try NIOSSLContext(configuration: configuration)
            if cache.count >= contextLimit {
                cache.removeAll()
            }
            cache[key] = context
            return context
        }
    }

    /// 在已连接的 Channel 上完成 TLS 握手。握手超过 `deadline` 时失败（`TLS-005`）。
    public static func handshake(
        on channel: any Channel, serverHost: String, options: TLSClientOptions, deadline: NIODeadline
    ) -> EventLoopFuture<any Channel> {
        let eventLoop = channel.eventLoop
        let handler: NIOSSLClientHandler
        do {
            let context = try context(for: options)
            let serverName = options.effectiveServerName(serverHost: serverHost)
            if let fingerprint = options.certificateFingerprintSHA256 {
                handler = try NIOSSLClientHandler(
                    context: context, serverHostname: serverName,
                    customVerificationCallback: { certificates, promise in
                        guard let leaf = certificates.first, let der = try? leaf.toDERBytes() else {
                            promise.succeed(.failed)
                            return
                        }
                        promise.succeed(Array(SHA256.hash(data: der)) == fingerprint ? .certificateVerified : .failed)
                    })
            } else {
                handler = try NIOSSLClientHandler(context: context, serverHostname: serverName)
            }
        } catch {
            return eventLoop.makeFailedFuture(TLSError(.tlsNegotiationFailed, "TLS setup failed: \(error)"))
        }
        let promise = eventLoop.makePromise(of: (any Channel).self)
        let waiter = TLSHandshakeWaiter(
            promise: promise, fingerprintPinned: options.certificateFingerprintSHA256 != nil)
        do {
            try channel.pipeline.syncOperations.addHandler(handler)
            try channel.pipeline.syncOperations.addHandler(waiter)
        } catch {
            return eventLoop.makeFailedFuture(TLSError(.tlsNegotiationFailed, "\(error)"))
        }
        ChannelTuning.startReading(channel)
        let timer = eventLoop.scheduleTask(deadline: deadline) {
            promise.fail(TLSError(.tlsHandshakeTimeout, "TLS handshake timed out"))
            channel.close(promise: nil)
        }
        promise.futureResult.whenComplete { _ in timer.cancel() }
        return promise.futureResult
    }

    /// 把 NIOSSL 的错误映射为 `TLS` 码。
    static func map(_ error: any Error, fingerprintPinned: Bool) -> TLSError {
        if let tlsError = error as? TLSError {
            return tlsError
        }
        let text = String(describing: error)
        if let ssl = error as? NIOSSLError {
            switch ssl {
            case .handshakeFailed(let underlying):
                let detail = "\(underlying)"
                if fingerprintPinned, detail.contains("CERTIFICATE_VERIFY_FAILED") {
                    return TLSError(.tlsFingerprintMismatch, "Leaf certificate fingerprint does not match")
                }
                if detail.contains("CERTIFICATE_VERIFY_FAILED") {
                    return TLSError(.tlsCertificateInvalid, detail)
                }
                return TLSError(.tlsNegotiationFailed, detail)
            case .unableToValidateCertificate:
                return TLSError(.tlsCertificateInvalid, text)
            default:
                return TLSError(.tlsNegotiationFailed, text)
            }
        }
        if let verification = error as? NIOSSLExtraError, verification == .failedToValidateHostname {
            return TLSError(.tlsHostnameMismatch, text)
        }
        return TLSError(.tlsNegotiationFailed, text)
    }
}

/// 等待握手完成后移除自己。
private final class TLSHandshakeWaiter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<any Channel>
    private let fingerprintPinned: Bool

    init(promise: EventLoopPromise<any Channel>, fingerprintPinned: Bool) {
        self.promise = promise
        self.fingerprintPinned = fingerprintPinned
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case .some(.handshakeCompleted) = event as? TLSUserEvent {
            let channel = context.channel
            ChannelTuning.stopReading(channel)
            context.pipeline.syncOperations.removeHandler(context: context, promise: nil)
            promise.succeed(channel)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        promise.fail(TLSTransport.map(error, fingerprintPinned: fingerprintPinned))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(TLSError(.tlsNegotiationFailed, "Connection closed during TLS handshake"))
        context.fireChannelInactive()
    }
}

@available(*, unavailable)
extension TLSHandshakeWaiter: Sendable {}
