import AetherFoundation
import AetherOutbound
import NIOHTTP1
import Testing

@testable import AetherHTTP

@Suite("HTTP proxy request parsing")
struct ProxyParsingTests {
    @Test("Absolute-form targets")
    func absoluteTargets() throws {
        let plain = try #require(AbsoluteTarget(uri: "http://www.example.com/path?q=1#frag"))
        #expect(plain.host == "www.example.com" && plain.port == 80)
        #expect(plain.originForm == "/path?q=1")
        #expect(plain.authority == "www.example.com")

        let withPort = try #require(AbsoluteTarget(uri: "HTTP://user:pw@example.com:8080"))
        #expect(withPort.port == 8080 && withPort.originForm == "/" && withPort.authority == "example.com:8080")

        let v6 = try #require(AbsoluteTarget(uri: "http://[2001:db8::1]:81?x"))
        #expect(v6.host == "2001:db8::1" && v6.port == 81 && v6.originForm == "/?x")

        #expect(AbsoluteTarget(uri: "/relative") == nil)
        #expect(AbsoluteTarget(uri: "https://example.com/") == nil)
        #expect(AbsoluteTarget(uri: "http://example.com:0/") == nil)
        #expect(AbsoluteTarget(uri: "http:///path") == nil)
    }

    @Test("CONNECT targets")
    func connectTargets() {
        #expect(ConnectTarget.parse("example.com:443") == .domain(Hostname("example.com")!, port: 443))
        #expect(ConnectTarget.parse("192.0.2.1:8443") == .ip(IPAddress("192.0.2.1")!, port: 8443))
        #expect(ConnectTarget.parse("[2001:db8::1]:443") == .ip(IPAddress("2001:db8::1")!, port: 443))
        #expect(ConnectTarget.parse("example.com") == nil)
        #expect(ConnectTarget.parse("example.com:http") == nil)
    }

    @Test("Hop-by-hop headers and the ones Connection lists are removed")
    func hopByHop() {
        var headers = HTTPHeaders([
            ("Host", "example.com"), ("Connection", "keep-alive, X-Secret"), ("Proxy-Connection", "keep-alive"),
            ("Proxy-Authorization", "Basic xyz"), ("X-Secret", "1"), ("Keep-Alive", "timeout=5"),
            ("Transfer-Encoding", "chunked"), ("Accept", "*/*"),
        ])
        HTTPHopByHop.strip(&headers)
        #expect(headers.map(\.name) == ["Host", "Transfer-Encoding", "Accept"])
    }
}
