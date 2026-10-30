import AetherFoundation
import AetherOutbound
import AetherTestSupport
import Crypto
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import Testing

// 互通测试（docs/13 §3）：由 Scripts/interop/run.sh 启动真实服务端后运行；没有 AETHER_INTEROP=1 时整体跳过。
// 只使用公开 API（不 @testable），与产品的调用方式一致。

enum Interop {
    static let environment = ProcessInfo.processInfo.environment
    static let enabled = environment["AETHER_INTEROP"] == "1"
    static let obfsAvailable = environment["AETHER_INTEROP_OBFS"] == "1"
    static var user: String { environment["AETHER_INTEROP_USER"] ?? "" }
    static var password: String { environment["AETHER_INTEROP_PASSWORD"] ?? "" }
    static let caPEM: String =
        (try? String(contentsOfFile: environment["AETHER_INTEROP_CA"] ?? "", encoding: .utf8)) ?? ""

    static func port(_ key: String) -> UInt16 {
        UInt16(environment[key] ?? "") ?? 0
    }

    /// 校验测试 CA 签发的 `interop.example.com` 证书。
    static var tls: TLSClientOptions {
        var options = TLSClientOptions()
        options.serverName = .custom("interop.example.com")
        options.additionalTrustRootsPEM = [caPEM]
        return options
    }

    static func server(_ portKey: String, tls: Bool = false) -> ProxyServer {
        ProxyServer(host: "127.0.0.1", port: port(portKey), tls: tls ? Interop.tls : nil)
    }

    /// 报告行写入 `AETHER_INTEROP_REPORT`（run.sh 汇总为 CI 摘要）。
    private static let reportLock = NIOLock()

    static func report(_ row: String) {
        guard let path = environment["AETHER_INTEROP_REPORT"] else { return }
        reportLock.withLock {
            let line = Data((row + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: line)
            }
        }
    }
}

/// 一个协议 × 传输组合。`make(true)` 用正确凭据，`make(false)` 用错误凭据。
struct InteropCase: Sendable, CustomTestStringConvertible {
    let name: String
    let udp: Bool
    let make: @Sendable (_ validCredentials: Bool) -> any OutboundConnector

    var testDescription: String { name }

    static var all: [InteropCase] {
        let user = Interop.user
        @Sendable func password(_ valid: Bool) -> String { valid ? Interop.password : "wrong-password" }
        var cases: [InteropCase] = [
            InteropCase(name: "HTTP", udp: false) {
                HTTPConnectConnector(
                    name: "HTTP", server: Interop.server("XRAY_HTTP_PORT"), username: user, password: password($0))
            },
            InteropCase(name: "HTTPS", udp: false) {
                HTTPConnectConnector(
                    name: "HTTPS", server: Interop.server("XRAY_HTTPS_PORT", tls: true), username: user,
                    password: password($0))
            },
            InteropCase(name: "SOCKS5", udp: true) {
                SOCKS5Connector(
                    name: "SOCKS5", server: Interop.server("XRAY_SOCKS_PORT"), username: user, password: password($0),
                    udpEnabled: true)
            },
            InteropCase(name: "SOCKS5-TLS", udp: true) {
                SOCKS5Connector(
                    name: "SOCKS5-TLS", server: Interop.server("XRAY_SOCKS_TLS_PORT", tls: true), username: user,
                    password: password($0), udpEnabled: true)
            },
        ]
        cases.append(
            InteropCase(name: "Trojan TLS", udp: true) {
                TrojanConnector(
                    name: "Trojan", server: Interop.server("XRAY_TROJAN_TLS_PORT", tls: true), password: password($0),
                    udpEnabled: true)
            })
        cases.append(
            InteropCase(name: "Trojan WS+TLS", udp: true) {
                var server = Interop.server("XRAY_TROJAN_WS_TLS_PORT", tls: true)
                server.webSocket = WebSocketClientOptions(path: "/trojan")
                return TrojanConnector(name: "Trojan", server: server, password: password($0), udpEnabled: true)
            })
        let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
        @Sendable func vlessUUID(_ valid: Bool) -> String { valid ? uuid : "00000000-0000-4000-8000-000000000000" }
        cases.append(
            InteropCase(name: "VLESS TLS", udp: true) {
                VLESSConnector(
                    name: "VLESS", server: Interop.server("XRAY_VLESS_TLS_PORT", tls: true), uuid: vlessUUID($0),
                    udpEnabled: true)!
            })
        cases.append(
            InteropCase(name: "VLESS WS+TLS", udp: true) {
                var server = Interop.server("XRAY_VLESS_WS_TLS_PORT", tls: true)
                server.webSocket = WebSocketClientOptions(path: "/vless")
                return VLESSConnector(name: "VLESS", server: server, uuid: vlessUUID($0), udpEnabled: true)!
            })
        let vmessVariants: [(String, String, VMessSecurity, Bool, Bool)] = [
            ("VMess TCP aes-128-gcm", "XRAY_VMESS_TCP_PORT", .aes128GCM, false, false),
            ("VMess TCP chacha20-poly1305", "XRAY_VMESS_TCP_PORT", .chacha20Poly1305, false, false),
            ("VMess TCP none", "XRAY_VMESS_TCP_PORT", VMessSecurity.none, false, false),
            ("VMess WS", "XRAY_VMESS_WS_PORT", .aes128GCM, true, false),
            ("VMess WS+TLS", "XRAY_VMESS_WS_TLS_PORT", .aes128GCM, true, true),
        ]
        for (name, key, security, webSocket, tls) in vmessVariants {
            cases.append(
                InteropCase(name: name, udp: true) {
                    var server = Interop.server(key, tls: tls)
                    server.webSocket = webSocket ? WebSocketClientOptions(path: "/vmess") : nil
                    return VMessConnector(
                        name: "VMess", server: server, uuid: vlessUUID($0), security: security, udpEnabled: true)!
                })
        }
        let shadowsocks: [(String, ShadowsocksAEADMethod)] = [
            ("SS_AES128_PORT", .aes128GCM), ("SS_AES256_PORT", .aes256GCM), ("SS_CHACHA_PORT", .chacha20IETFPoly1305),
        ]
        for (key, method) in shadowsocks {
            cases.append(
                InteropCase(name: "SS \(method.rawValue)", udp: true) {
                    ShadowsocksConnector(
                        name: "SS", server: Interop.server(key), method: method, password: password($0),
                        udpEnabled: true)
                })
        }
        if Interop.obfsAvailable {
            cases.append(
                InteropCase(name: "SS aes-256-gcm + obfs-http", udp: false) {
                    ShadowsocksConnector(
                        name: "SS", server: Interop.server("SS_OBFS_HTTP_PORT"), method: .aes256GCM,
                        password: password($0), obfs: SimpleObfsHTTPOptions(host: "cdn.example.com"),
                        udpEnabled: false)
                })
        }
        return cases
    }
}

@Suite("Interop (13 §3)", .enabled(if: Interop.enabled), .serialized)
struct InteropTests {
    @Test("Protocol × transport against real servers", arguments: InteropCase.all)
    func interop(_ testCase: InteropCase) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let origin = try await HTTPTestOrigin.start(group: group)
        let udpServers = try await InteropUDPServers.start(group: group)
        let client = InteropClient(group: group, originPort: UInt16(origin.port))
        let connector = testCase.make(true)
        var row: [String] = [testCase.name]

        // 1. 小文件内容一致。
        let small = try? await client.get(connector, path: "/bytes/1024")
        let smallOK = small?.status == 200 && small?.prefix == InteropClient.pattern(count: 1024)
        #expect(smallOK, "GET /bytes/1024")
        row.append(smallOK ? "✅" : "❌")

        // 2. 64 MiB 下载：SHA-256 一致，记录吞吐。
        let large = 64 * 1024 * 1024
        let started = ContinuousClock.now
        let big = try? await client.get(connector, path: "/bytes/\(large)", timeout: .seconds(300))
        let elapsed = ContinuousClock.now - started
        let bigOK = big?.complete == true && big?.bytes == large && big?.sha256 == InteropClient.largeDigest
        #expect(bigOK, "64 MiB download")
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        row.append(bigOK ? String(format: "✅ %.1f MB/s", Double(large) / 1_048_576 / max(seconds, 0.001)) : "❌")

        // 3. 50 个并发连接。
        let concurrent = await withTaskGroup(of: Bool.self) { tasks in
            for _ in 0..<50 {
                tasks.addTask {
                    let result = try? await client.get(connector, path: "/bytes/65536")
                    return result?.complete == true && result?.sha256 == InteropClient.digest(count: 65536)
                }
            }
            return await tasks.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(concurrent == 50, "50 concurrent connections")
        row.append(concurrent == 50 ? "✅" : "❌ \(concurrent)/50")

        // 4. 服务端中途断开：连接结束且没有收全，不挂起。
        let aborted = try? await client.get(connector, path: "/abort/1048576", timeout: .seconds(20))
        let abortOK = aborted.map { !$0.complete && $0.bytes < 1_048_576 } ?? false
        #expect(abortOK, "server abort ends the connection")
        row.append(abortOK ? "✅" : "❌")

        // 5. 错误凭据：拿不到源站内容（连接失败、被关闭，或服务端防探测地保持沉默直到超时）。
        let wrong: String
        do {
            let result = try await client.get(testCase.make(false), path: "/bytes/1024", timeout: .seconds(5))
            wrong = result.status == 200 && result.complete ? "❌ data" : "✅ closed"
        } catch let error as NetworkError {
            wrong = "✅ \(error.code.rawValue)"
        } catch is InteropClient.Timeout {
            wrong = "✅ silent"
        } catch {
            wrong = "✅ \(type(of: error))"
        }
        #expect(!wrong.hasPrefix("❌"), "wrong credentials must not reach the origin")
        row.append(wrong)

        // 6. UDP：DNS 查询与 1000 个回显包。
        if testCase.udp {
            let udp = try? await client.udpChecks(connector, servers: udpServers)
            let udpOK = udp.map { $0.dnsAnswered && $0.received >= 990 } ?? false
            #expect(udpOK, "UDP: \(String(describing: udp))")
            row.append(
                udp.map {
                    "\(udpOK ? "✅" : "❌") DNS \($0.dnsAnswered ? "ok" : "no"), loss \(String(format: "%.1f", Double(1000 - $0.received) / 10))%, reordered \($0.reordered)"
                } ?? "❌")
        } else {
            row.append("—")
        }

        // 7. 测速：generate_204。
        let latencyStart = ContinuousClock.now
        let probe = try? await client.get(connector, path: "/generate_204")
        let latency = ContinuousClock.now - latencyStart
        #expect(probe?.status == 204, "generate_204")
        row.append(
            probe?.status == 204
                ? "✅ \(latency.components.attoseconds / 1_000_000_000_000_000 + latency.components.seconds * 1000) ms"
                : "❌")

        Interop.report("| " + row.joined(separator: " | ") + " |")
        try await udpServers.close()
        try await origin.close()
        try await group.shutdownGracefully()
    }
}
