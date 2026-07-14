import Foundation
import Testing
@testable import ClaudeStatusLight

struct SettingsRelayTests {
    @Test func statusLineAndButtonAdaptToConfig() {
        #expect(SettingsWindowController.relayStatusText(config: nil) == "not set up")
        #expect(SettingsWindowController.relayButtonTitle(config: nil) == "Set up Cloudflare relay…")

        let config = RelayConfig(url: URL(string: "https://claude-status-relay.luke.workers.dev")!,
                                 token: "t", host: "h")
        #expect(SettingsWindowController.relayStatusText(config: config)
                == "relay: https://claude-status-relay.luke.workers.dev")
        #expect(SettingsWindowController.relayButtonTitle(config: config) == "Re-deploy relay…")
    }

    @Test func remoteStoreCanBeStoppedAndReplaced() {
        let store = RemoteStore(config: RelayConfig(url: URL(string: "https://x")!, token: "t", host: "h"))
        store.start()
        store.stop()   // must not crash, must be idempotent
        store.stop()
    }

    @Test func pairButtonOnlyShowsWhenConfigured() {
        #expect(SettingsWindowController.pairButtonHidden(config: nil))
        let config = RelayConfig(url: URL(string: "https://x")!, token: "t", host: "h")
        #expect(!SettingsWindowController.pairButtonHidden(config: config))
    }
}
