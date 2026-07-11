import Foundation
import Testing
@testable import ClaudeStatusLight

struct RemoteStoreTests {
    private func wire(
        id: String = "s1", state: String = "working", updatedAt: Double = 1_000
    ) -> WireSession {
        WireSession(
            sessionID: id, state: state, cwd: "/p/proj", termProgram: "iTerm.app",
            tty: "", updatedAt: updatedAt, agents: 0, title: nil, shells: [], background: false
        )
    }

    private func snapshot(
        now: Double = 10_000,
        hosts: [WireHost] = [],
        cloud: [WireCloudSession] = []
    ) -> WireSnapshot {
        WireSnapshot(now: now, hosts: hosts, cloud: cloud)
    }

    @Test func freshHostSessionsComeThroughWithOrigin() {
        let snap = snapshot(hosts: [WireHost(name: "mini", receivedAt: 9_990, sessions: [wire()])])
        let sessions = RemoteStore.sessions(from: snap)
        #expect(sessions.count == 1)
        #expect(sessions.first?.origin == "mini")
    }

    @Test func staleHostIsDroppedEntirely() {
        // 61s since the host's last snapshot — past the 60s window.
        let snap = snapshot(hosts: [WireHost(name: "mini", receivedAt: 10_000 - 61, sessions: [wire()])])
        #expect(RemoteStore.sessions(from: snap).isEmpty)
    }

    @Test func expiredCloudSessionIsDropped() {
        let fresh = WireCloudSession(sessionID: "c1", state: "idle", repo: "r", agents: 0, receivedAt: 9_000)
        let stale = WireCloudSession(sessionID: "c2", state: "idle", repo: "r", agents: 0, receivedAt: 10_000 - 1_801)
        let sessions = RemoteStore.sessions(from: snapshot(cloud: [fresh, stale]))
        #expect(sessions.map(\.sessionID) == ["c1"])
    }

    @Test func unknownStatesAreDroppedNotGuessed() {
        let snap = snapshot(hosts: [WireHost(name: "mini", receivedAt: 9_990, sessions: [wire(state: "levitating")])])
        #expect(RemoteStore.sessions(from: snap).isEmpty)
    }

    @Test func mergeSortsByRecency() {
        let older = wire(id: "old", updatedAt: 1_000).sessionState(origin: "mini")!
        let newer = wire(id: "new", updatedAt: 2_000).sessionState(origin: "mini")!
        let local = SessionState(
            sessionID: "local", state: .idle, cwd: "/p", termProgram: "t", tty: "",
            pid: 1, updatedAt: Date(timeIntervalSince1970: 1_500), agents: 0, title: nil, shells: []
        )
        let merged = RemoteStore.merge(local: [local], remote: [older, newer])
        #expect(merged.map(\.sessionID) == ["new", "local", "old"])
    }

    @Test func unconfiguredStoreIsInertAndReachable() {
        let store = RemoteStore(config: nil)
        #expect(store.isConfigured == false)
        #expect(store.unreachable == false)
        #expect(store.sessions().isEmpty)
    }

    @Test func staleResponseCannotOverwriteNewerSnapshot() {
        // A slow poll response arriving after a newer one must be ignored.
        let store = RemoteStore(config: nil)
        let newer = snapshot(
            now: 10_000,
            hosts: [WireHost(name: "mini", receivedAt: 9_990, sessions: [wire(id: "keep")])]
        )
        let older = snapshot(
            now: 9_000,
            hosts: [WireHost(name: "mini", receivedAt: 8_990, sessions: [wire(id: "late")])]
        )
        store.ingest(newer)
        store.ingest(older)
        #expect(store.sessions().map(\.sessionID) == ["keep"])
    }

    @Test func relayConfigLoads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("relay.json")
        try Data(#"{"url":"https://relay.example.workers.dev","token":"tok","host":"mini"}"#.utf8)
            .write(to: file)

        let config = try #require(RelayConfig.load(from: file))
        #expect(config.url.absoluteString == "https://relay.example.workers.dev")
        #expect(config.token == "tok")
        #expect(config.host == "mini")
        #expect(RelayConfig.load(from: dir.appendingPathComponent("missing.json")) == nil)
    }
}
