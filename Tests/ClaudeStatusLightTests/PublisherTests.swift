import Foundation
import Testing
@testable import ClaudeStatusLight

struct PublisherTests {
    private func session(id: String, updatedAt: Double = 1_000) -> SessionState {
        SessionState(
            sessionID: id, state: .idle, cwd: "/p", termProgram: "t", tty: "",
            pid: 1, updatedAt: Date(timeIntervalSince1970: updatedAt),
            agents: 0, title: nil, shells: []
        )
    }

    @Test func snapshotEncodingIsDeterministic() throws {
        // Same sessions, either order → byte-identical payloads, so change
        // detection can compare Data directly.
        let a = try #require(Publisher.encodeSnapshot([session(id: "a"), session(id: "b")]))
        let b = try #require(Publisher.encodeSnapshot([session(id: "b"), session(id: "a")]))
        #expect(a == b)

        let obj = try JSONSerialization.jsonObject(with: a) as? [String: Any]
        let sessions = obj?["sessions"] as? [[String: Any]]
        #expect(sessions?.count == 2)
        #expect(sessions?.first?["session_id"] as? String == "a")
    }

    @Test func pushesOnChangeOrHeartbeat() {
        let payload = Data("new".utf8)
        let old = Data("old".utf8)
        let now = Date(timeIntervalSince1970: 10_000)

        // First run: nothing pushed yet.
        #expect(Publisher.shouldPush(payload: payload, lastPayload: nil, lastPush: .distantPast, now: now))
        // Changed content pushes immediately.
        #expect(Publisher.shouldPush(payload: payload, lastPayload: old, lastPush: now, now: now))
        // Unchanged content within the heartbeat window stays quiet.
        #expect(!Publisher.shouldPush(payload: payload, lastPayload: payload,
                                      lastPush: now.addingTimeInterval(-14), now: now))
        // Unchanged content past 15s heartbeats anyway (it is the liveness signal).
        #expect(Publisher.shouldPush(payload: payload, lastPayload: payload,
                                     lastPush: now.addingTimeInterval(-15), now: now))
    }
}
