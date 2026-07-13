import CryptoKit
import Foundation
import Testing
@testable import ClaudeStatusLight

/// Guards the generated worker bundle against drifting from relay/src.
struct RelayWorkerDistTests {
    /// Tests/ClaudeStatusLightTests/RelayWorkerDistTests.swift → repo root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    @Test func distMatchesRelaySources() throws {
        let src = repoRoot.appendingPathComponent("relay/src")
        var blob = Data()
        for name in ["classify.ts", "env.d.ts", "index.ts", "relay-do.ts"] {
            blob.append(try Data(contentsOf: src.appendingPathComponent(name)))
        }
        let hash = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        #expect(hash == RelayWorkerDist.sourceHash,
                "relay/src changed — run scripts/build-relay-dist.sh and commit the result")
    }

    @Test func distLooksLikeTheBundledWorker() {
        #expect(RelayWorkerDist.moduleJS.contains("RelayDO"))
        #expect(RelayWorkerDist.moduleJS.count > 1000)
    }
}
