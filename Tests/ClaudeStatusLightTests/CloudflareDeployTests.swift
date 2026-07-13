import Foundation
import Testing
@testable import ClaudeStatusLight

struct CloudflareDeployTests {
    private let envelope = { (result: String) in
        #"{"success":true,"errors":[],"result":\#(result)}"#
    }
    /// accounts → script-exists probe → upload → enable subdomain → read
    /// subdomain → secret. Status for the probe parameterizes first-deploy.
    private func scriptedHTTP(existsStatus: Int) -> MockHTTP {
        MockHTTP([
            (200, envelope(#"[{"id":"acc1","name":"Luke"}]"#)),
            (existsStatus, existsStatus == 200 ? envelope(#"{"id":"claude-status-relay"}"#)
                                               : #"{"success":false,"errors":[{"code":10007,"message":"not found"}],"result":null}"#),
            (200, envelope(#"{"id":"claude-status-relay"}"#)),
            (200, envelope(#"{"enabled":true}"#)),
            (200, envelope(#"{"subdomain":"luke"}"#)),
            (200, envelope(#"{"name":"RELAY_TOKEN","type":"secret_text"}"#)),
        ])
    }
    private func tempConfigPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("deploy-test-\(UUID().uuidString)/relay.json")
    }

    @Test func firstDeployRunsAllStepsAndWritesConfig() async throws {
        let http = scriptedHTTP(existsStatus: 404)
        let deployer = CloudflareDeployer(http: http) { accounts in accounts[0] }
        let path = tempConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        var steps: [DeployStep] = []

        let config = try await deployer.deploy(accessToken: "tok", existing: nil,
                                               configPath: path) { steps.append($0) }

        #expect(config.url.absoluteString == "https://claude-status-relay.luke.workers.dev")
        #expect(config.token.count == 64)
        #expect(config.host == RelayConfig.shortHostname())
        #expect(RelayConfig.load(from: path) == config)
        #expect(steps == [.account, .upload, .url, .secret, .config])

        // 404 probe → the upload includes the first-run migration.
        let upload = String(data: http.requests[2].httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(upload.contains("new_sqlite_classes"))
        // The secret sent must be the token written to config.
        let secret = String(data: http.requests[5].httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(secret.contains(config.token))
    }

    @Test func redeployKeepsTokenAndSkipsMigration() async throws {
        let http = scriptedHTTP(existsStatus: 200)
        let deployer = CloudflareDeployer(http: http) { accounts in accounts[0] }
        let path = tempConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }
        let existing = RelayConfig(url: URL(string: "https://old")!, token: "old-token", host: "laptop")

        let config = try await deployer.deploy(accessToken: "tok", existing: existing,
                                               configPath: path) { _ in }

        #expect(config.token == "old-token")
        #expect(config.host == "laptop")
        let upload = String(data: http.requests[2].httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(!upload.contains("migrations"))
    }

    @Test func apiErrorsSurfaceCloudflareMessages() async throws {
        let http = MockHTTP([
            (403, #"{"success":false,"errors":[{"code":10000,"message":"Authentication error"}],"result":null}"#),
        ])
        let deployer = CloudflareDeployer(http: http) { accounts in accounts[0] }
        await #expect(throws: CFAPIError.self) {
            try await deployer.deploy(accessToken: "tok", existing: nil,
                                      configPath: self.tempConfigPath()) { _ in }
        }
    }

    @Test func multipleAccountsGoThroughThePicker() async throws {
        let http = scriptedHTTP(existsStatus: 404)
        http.responses[0] = (200, envelope(#"[{"id":"a1","name":"One"},{"id":"a2","name":"Two"}]"#))
        var offered: [CFAccount] = []
        let deployer = CloudflareDeployer(http: http) { accounts in
            offered = accounts
            return accounts[1]
        }
        let path = tempConfigPath()
        defer { try? FileManager.default.removeItem(at: path.deletingLastPathComponent()) }

        _ = try await deployer.deploy(accessToken: "tok", existing: nil, configPath: path) { _ in }
        #expect(offered.count == 2)
        #expect(http.requests[1].url?.path.contains("/accounts/a2/") == true)
    }
}
