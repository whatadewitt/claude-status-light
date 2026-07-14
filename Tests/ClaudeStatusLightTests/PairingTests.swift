import Foundation
import Testing
@testable import ClaudeStatusLight

struct PairingTests {
    private let config = RelayConfig(
        url: URL(string: "https://claude-status-relay.luke.workers.dev")!,
        token: "tok", host: "studio")

    @Test func requestPostsConfigToPairWithBearer() throws {
        let request = try #require(Pairing.request(config: config))
        #expect(request.url?.absoluteString
                == "https://claude-status-relay.luke.workers.dev/pair")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(request.httpBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        // No "host": the receiving machine writes its own.
        #expect(obj == ["url": "https://claude-status-relay.luke.workers.dev", "token": "tok"])
    }

    @Test func decodeParsesCodeAndExpiry() {
        let data = Data(#"{"code":"abc123","expires_at":1752000600}"#.utf8)
        #expect(Pairing.decode(data) == Pairing.Response(code: "abc123", expiresAt: 1_752_000_600))
    }

    @Test func decodeRejectsGarbageAndEmptyCodes() {
        #expect(Pairing.decode(Data("nope".utf8)) == nil)
        #expect(Pairing.decode(Data(#"{"code":"","expires_at":1}"#.utf8)) == nil)
        #expect(Pairing.decode(Data(#"{"expires_at":1}"#.utf8)) == nil)
    }

    @Test func commandMatchesInstallPublisherFlag() {
        #expect(Pairing.command(url: config.url, code: "cafe01") ==
            "scripts/install-publisher.sh --pair https://claude-status-relay.luke.workers.dev cafe01")
    }
}
