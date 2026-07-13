import Foundation
import Testing
@testable import ClaudeStatusLight

struct CloudflareAPITests {
    private let base = "https://api.cloudflare.com/client/v4"

    @Test func requestsHitTheDocumentedEndpointsWithBearerAuth() throws {
        let accounts = CloudflareAPI.accountsRequest(token: "tok")
        #expect(accounts.url?.absoluteString == "\(base)/accounts")
        #expect(accounts.value(forHTTPHeaderField: "Authorization") == "Bearer tok")

        let exists = CloudflareAPI.scriptExistsRequest(account: "acc1", token: "tok")
        #expect(exists.url?.absoluteString == "\(base)/accounts/acc1/workers/scripts/claude-status-relay")

        let enable = CloudflareAPI.enableSubdomainRequest(account: "acc1", token: "tok")
        #expect(enable.httpMethod == "POST")
        #expect(enable.url?.absoluteString == "\(base)/accounts/acc1/workers/scripts/claude-status-relay/subdomain")
        #expect(String(data: enable.httpBody ?? Data(), encoding: .utf8) == #"{"enabled":true}"#)

        let sub = CloudflareAPI.accountSubdomainRequest(account: "acc1", token: "tok")
        #expect(sub.url?.absoluteString == "\(base)/accounts/acc1/workers/subdomain")
    }

    @Test func uploadRequestIsWellFormedMultipart() throws {
        let request = CloudflareAPI.uploadRequest(
            account: "acc1", includeMigration: true, moduleJS: "export default {};",
            boundary: "BOUNDARY", token: "tok")
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "\(base)/accounts/acc1/workers/scripts/claude-status-relay")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")

        let body = String(data: try #require(request.httpBody), encoding: .utf8)!
        #expect(body.contains(#"Content-Disposition: form-data; name="metadata""#))
        #expect(body.contains(#"Content-Disposition: form-data; name="index.js"; filename="index.js""#))
        #expect(body.contains("Content-Type: application/javascript+module"))
        #expect(body.contains("export default {};"))
        #expect(body.hasSuffix("--BOUNDARY--\r\n"))

        // The metadata part must decode to the documented shape.
        let metaLine = try #require(
            body.components(separatedBy: "\r\n").first { $0.hasPrefix("{") && $0.contains("main_module") })
        let meta = try #require(
            try JSONSerialization.jsonObject(with: Data(metaLine.utf8)) as? [String: Any])
        #expect(meta["main_module"] as? String == "index.js")
        #expect(meta["compatibility_date"] as? String == "2026-07-10")
        #expect(meta["compatibility_flags"] as? [String] == ["nodejs_compat"])
        let binding = try #require((meta["bindings"] as? [[String: Any]])?.first)
        #expect(binding["type"] as? String == "durable_object_namespace")
        #expect(binding["name"] as? String == "RELAY")
        #expect(binding["class_name"] as? String == "RelayDO")
        let migrations = try #require(meta["migrations"] as? [String: Any])
        #expect(migrations["new_tag"] as? String == "v1")
        let step = try #require((migrations["steps"] as? [[String: Any]])?.first)
        #expect(step["new_sqlite_classes"] as? [String] == ["RelayDO"])
    }

    @Test func redeployOmitsTheMigration() throws {
        let request = CloudflareAPI.uploadRequest(
            account: "acc1", includeMigration: false, moduleJS: "x",
            boundary: "B", token: "tok")
        let body = String(data: try #require(request.httpBody), encoding: .utf8)!
        #expect(!body.contains("migrations"))
    }

    @Test func secretRequestMatchesTheDocs() throws {
        let request = CloudflareAPI.secretRequest(account: "acc1", relayToken: "s3cret", token: "tok")
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "\(base)/accounts/acc1/workers/scripts/claude-status-relay/secrets")
        let body = try #require(
            try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String])
        #expect(body == ["name": "RELAY_TOKEN", "text": "s3cret", "type": "secret_text"])
    }

    @Test func workerURLAndTokenPreservation() {
        #expect(CloudflareAPI.workerURL(subdomain: "luke").absoluteString
                == "https://claude-status-relay.luke.workers.dev")

        let existing = RelayConfig(url: URL(string: "https://x")!, token: "keep-me", host: "h")
        #expect(CloudflareAPI.newRelayToken(existing: existing) == "keep-me")
        let fresh = CloudflareAPI.newRelayToken(existing: nil)
        #expect(fresh.count == 64)  // 32 random bytes, hex
        #expect(fresh.allSatisfy { $0.isHexDigit })
        #expect(CloudflareAPI.newRelayToken(existing: nil) != fresh)
    }

    @Test func envelopeDecodingSurfacesAPIErrors() throws {
        let ok = try JSONDecoder().decode(CFEnvelope<[CFAccount]>.self, from: Data(
            #"{"success":true,"errors":[],"result":[{"id":"a1","name":"Luke"}]}"#.utf8))
        #expect(ok.success && ok.result == [CFAccount(id: "a1", name: "Luke")])

        let bad = try JSONDecoder().decode(CFEnvelope<[CFAccount]>.self, from: Data(
            #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}"#.utf8))
        #expect(!bad.success)
        #expect(bad.errors.first?.message == "Authentication error")
    }

    @Test func relayConfigWritesOwnerOnlyJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-config-test-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("relay.json")
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = RelayConfig(url: URL(string: "https://r.example.workers.dev")!,
                                 token: "tok", host: "laptop")
        try config.write(to: file)
        #expect(RelayConfig.load(from: file) == config)
        let perms = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func shortHostnameHasNoDomainSuffix() {
        let host = RelayConfig.shortHostname()
        #expect(!host.isEmpty)
        #expect(!host.contains("."))
    }
}
