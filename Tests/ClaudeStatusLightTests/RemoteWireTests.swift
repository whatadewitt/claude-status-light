import Foundation
import Testing
@testable import ClaudeStatusLight

struct RemoteWireTests {
    @Test func wireSessionRoundTripsFromSessionState() throws {
        let local = SessionState(
            sessionID: "abc", state: .working, cwd: "/Users/luke/proj",
            termProgram: "iTerm.app", tty: "/dev/ttys001", pid: 42,
            updatedAt: Date(timeIntervalSince1970: 1_752_000_000),
            agents: 2, title: "Improve win rate", shells: ["uv run train.py"]
        )
        let wire = WireSession(from: local)
        let data = try JSONEncoder().encode(wire)
        let decoded = try JSONDecoder().decode(WireSession.self, from: data)
        let remote = try #require(decoded.sessionState(origin: "office-mini"))

        #expect(remote.sessionID == "abc")
        #expect(remote.state == .working)
        #expect(remote.origin == "office-mini")
        #expect(remote.pid == nil)
        #expect(remote.updatedAt == Date(timeIntervalSince1970: 1_752_000_000))
        #expect(remote.agents == 2)
        #expect(remote.title == "Improve win rate")
        #expect(remote.shells == ["uv run train.py"])
        #expect(remote.backgroundOverride == false)  // local had a tty
    }

    @Test func wireUsesSnakeCaseKeys() throws {
        let local = SessionState(
            sessionID: "abc", state: .idle, cwd: "/p", termProgram: "t", tty: "",
            pid: 42, updatedAt: Date(timeIntervalSince1970: 1), agents: 0,
            title: nil, shells: []
        )
        let json = String(decoding: try JSONEncoder().encode(WireSession(from: local)), as: UTF8.self)
        #expect(json.contains("\"session_id\""))
        #expect(json.contains("\"term_program\""))
        #expect(json.contains("\"updated_at\""))
        #expect(json.contains("\"background\":true"))  // pid + empty tty = background
    }

    @Test func unknownStateIsDropped() throws {
        let json = #"{"session_id":"x","state":"levitating","cwd":"/p","term_program":"t","tty":"","updated_at":1,"agents":0,"title":null,"shells":[],"background":false}"#
        let wire = try JSONDecoder().decode(WireSession.self, from: Data(json.utf8))
        #expect(wire.sessionState(origin: "h") == nil)
    }

    @Test func snapshotDecodesTheRelayShape() throws {
        let json = #"""
        {"now":1752000100,
         "hosts":[{"name":"office-mini","received_at":1752000090,
                   "sessions":[{"session_id":"abc","state":"idle","cwd":"/p","term_program":"t","tty":"","updated_at":1752000000,"agents":0,"title":null,"shells":[],"background":true}]}],
         "cloud":[{"session_id":"c1","state":"attention","repo":"my-repo","agents":1,"received_at":1752000095}]}
        """#
        let snapshot = try JSONDecoder().decode(WireSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.now == 1_752_000_100)
        #expect(snapshot.hosts.first?.name == "office-mini")
        #expect(snapshot.hosts.first?.sessions.first?.sessionID == "abc")

        let cloud = try #require(snapshot.cloud.first?.sessionState())
        #expect(cloud.origin == "cloud")
        #expect(cloud.state == .attention)
        #expect(cloud.project == "my-repo")   // repo string flows through cwd
        #expect(cloud.backgroundOverride == true)
        #expect(cloud.agents == 1)
    }
}
