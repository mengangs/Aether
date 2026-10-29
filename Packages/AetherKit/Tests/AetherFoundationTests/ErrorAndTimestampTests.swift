import Foundation
import Testing

@testable import AetherFoundation

struct AetherErrorCodeTests {
    @Test(arguments: ["NET-002", "CFG-099", "MITM-010", "IPC-020", "STO-001"])
    func wellFormed(_ raw: String) {
        let code = AetherErrorCode(rawValue: raw)
        #expect(code.isWellFormed)
        #expect(code.namespace != nil)
    }

    @Test(arguments: ["NET-2", "XYZ-001", "NET001", "net-001", "NET-0012", "NET-00A", ""])
    func malformed(_ raw: String) {
        let code = AetherErrorCode(rawValue: raw)
        #expect(!code.isWellFormed)
        #expect(code.namespace == nil)
    }

    @Test func codableAsPlainString() throws {
        let data = try JSONEncoder().encode(["code": AetherErrorCode("DNS-003")])
        #expect(String(decoding: data, as: UTF8.self) == #"{"code":"DNS-003"}"#)
        let decoded = try JSONDecoder().decode([String: AetherErrorCode].self, from: data)
        #expect(decoded["code"]?.namespace == .dns)
    }
}

struct LogTimestampTests {
    @Test(arguments: [
        (0.0, "1970-01-01T00:00:00.000Z"),
        (951_782_400.5, "2000-02-29T00:00:00.500Z"),
        (1_793_347_200.123, "2026-10-30T08:00:00.123Z"),
        (4_102_444_799.999, "2099-12-31T23:59:59.999Z"),
        (-1.0, "1969-12-31T23:59:59.000Z"),
    ])
    func formats(_ seconds: Double, _ expected: String) {
        #expect(LogTimestamp.format(Date(timeIntervalSince1970: seconds)) == expected)
    }
}

@Test func lockedValueIsConsistentUnderConcurrency() async {
    let counter = Locked(0)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                for _ in 0..<1000 {
                    counter.withLock { $0 += 1 }
                }
            }
        }
    }
    #expect(counter.current == 8000)
}
