import AetherIPC
import Foundation
import Testing

@testable import AetherEngine

struct IPCDispatcherTests {
    static let status = TunnelStatus(
        state: .running, since: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 1))

    let dispatcher = IPCDispatcher { command in
        switch command {
        case .getStatus:
            return .status(IPCDispatcherTests.status)
        }
    }

    private func decode(_ data: Data) throws -> IPCResponse {
        try IPCCodec.decode(IPCResponse.self, from: data)
    }

    @Test func answersGetStatus() async throws {
        let request = IPCRequest(command: .getStatus)
        let response = try decode(await dispatcher.handle(try IPCCodec.encode(request)))
        #expect(response.id == request.id)
        #expect(response.outcome == .success(.status(Self.status)))
    }

    @Test(arguments: [Data(), Data("garbage".utf8), Data("{}".utf8), Data(#"{"version":"1"}"#.utf8)])
    func undecodableMessageIsIPC003(_ message: Data) async throws {
        let response = try decode(await dispatcher.handle(message))
        #expect(response.id == IPCResponse.unknownRequestID)
        guard case .failure(let error) = response.outcome else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == "IPC-003")
    }

    @Test func unknownCommandIsIPC003WithRequestID() async throws {
        let id = UUID()
        let message = Data(#"{"version":1,"id":"\#(id.uuidString)","command":{"type":"warp"}}"#.utf8)
        let response = try decode(await dispatcher.handle(message))
        #expect(response.id == id)
        guard case .failure(let error) = response.outcome else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == "IPC-003")
    }

    @Test func versionMismatchIsIPC002() async throws {
        let request = IPCRequest(command: .getStatus, version: 2)
        let response = try decode(await dispatcher.handle(try IPCCodec.encode(request)))
        guard case .failure(let error) = response.outcome else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == "IPC-002")
        #expect(error.details?["appVersion"] == "2")
    }

    @Test func handlerErrorsAreReturned() async throws {
        struct Boom: Error {}
        let failing = IPCDispatcher { _ in throw Boom() }
        let response = try decode(await failing.handle(try IPCCodec.encode(IPCRequest(command: .getStatus))))
        guard case .failure(let error) = response.outcome else {
            Issue.record("expected failure")
            return
        }
        #expect(error.code == "IPC-012")
    }
}

@Test func emptyTunnelOnlyRoutesFakeIPRange() {
    let spec = TunnelNetworkSettingsSpec.emptyTunnel
    #expect(spec.ipv4.includedRoutes == [.init(destination: "198.18.0.0", mask: "255.254.0.0")])
    #expect(spec.ipv4.addresses == ["198.18.0.1"])
    #expect(spec.dns == nil)
    #expect(spec.tunnelRemoteAddress == "127.0.0.1")
}
