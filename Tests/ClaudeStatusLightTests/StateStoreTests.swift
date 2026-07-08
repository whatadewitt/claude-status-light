import Foundation
import Testing
@testable import ClaudeStatusLight

/// Each test gets its own temp sessions directory and a store pointed at it.
struct StateStoreTests {
    let dir: URL
    let store: StateStore

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("state-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = StateStore(sessionsDir: dir)
    }

    private func writeSession(
        id: String,
        state: String = "idle",
        pid: Int? = nil,
        tty: String = "",
        age: TimeInterval = 0,
        transcriptPath: String? = nil
    ) throws -> URL {
        var obj: [String: Any] = [
            "state": state,
            "session_id": id,
            "cwd": "/tmp/proj",
            "term_program": "iTerm.app",
            "tty": tty,
            "updated_at": Date().timeIntervalSince1970 - age,
        ]
        if let pid { obj["pid"] = pid }
        if let transcriptPath { obj["transcript_path"] = transcriptPath }
        let url = dir.appendingPathComponent("\(id).json")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url
    }

    /// A PID guaranteed dead: spawn a short-lived process and wait for it.
    private func deadPid() throws -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try proc.run()
        proc.waitUntilExit()
        return Int(proc.processIdentifier)
    }

    // MARK: - PID liveness

    @Test func keepsSessionWithLivePid() throws {
        _ = try writeSession(id: "live", pid: Int(ProcessInfo.processInfo.processIdentifier))
        #expect(store.activeSessions().map(\.sessionID) == ["live"])
    }

    @Test func dropsSessionWithDeadPid() throws {
        _ = try writeSession(id: "dead", pid: try deadPid())
        #expect(store.activeSessions().isEmpty)
    }

    @Test func deletesFileOfDeadSession() throws {
        let url = try writeSession(id: "dead", pid: try deadPid())
        _ = store.activeSessions()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func livePidOverridesStaleWindow() throws {
        // A session untouched for a long time but whose process is alive is real.
        _ = try writeSession(
            id: "old-but-alive",
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            age: 13 * 60 * 60
        )
        #expect(store.activeSessions().map(\.sessionID) == ["old-but-alive"])
    }

    // MARK: - Legacy files (no pid) keep the time-based fallback

    @Test func keepsLegacySessionWithoutPidWhenFresh() throws {
        _ = try writeSession(id: "legacy")
        #expect(store.activeSessions().map(\.sessionID) == ["legacy"])
    }

    @Test func dropsLegacySessionOlderThanStaleWindow() throws {
        _ = try writeSession(id: "legacy-stale", age: 13 * 60 * 60)
        #expect(store.activeSessions().isEmpty)
    }

    @Test func pidZeroIsTreatedAsUnknownNotSignalled() throws {
        // The hook writes pid 0 when it can't identify its Claude ancestor.
        // That must fall back to the time window, never kill(0, 0).
        _ = try writeSession(id: "unknown-pid", pid: 0)
        _ = try writeSession(id: "unknown-pid-stale", pid: 0, age: 13 * 60 * 60)
        #expect(store.activeSessions().map(\.sessionID) == ["unknown-pid"])
    }

    // MARK: - Background detection

    @Test func sessionWithPidAndNoTtyIsBackground() throws {
        _ = try writeSession(id: "bg", pid: Int(ProcessInfo.processInfo.processIdentifier), tty: "")
        #expect(store.activeSessions().first?.isBackground == true)
    }

    @Test func sessionWithTtyIsNotBackground() throws {
        _ = try writeSession(id: "fg", pid: Int(ProcessInfo.processInfo.processIdentifier), tty: "/dev/ttys003")
        #expect(store.activeSessions().first?.isBackground == false)
    }

    @Test func legacySessionWithoutPidIsNotBackground() throws {
        // Old-format files always had an empty tty; don't mislabel them.
        _ = try writeSession(id: "legacy", tty: "")
        #expect(store.activeSessions().first?.isBackground == false)
    }

    // MARK: - Subagent markers

    /// The hook records one marker file per running subagent in <id>.agents/.
    private func writeAgentMarkers(id: String, count: Int) throws {
        let agentsDir = dir.appendingPathComponent("\(id).agents", isDirectory: true)
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)
        for i in 0..<count {
            FileManager.default.createFile(
                atPath: agentsDir.appendingPathComponent("marker-\(i)").path, contents: nil)
        }
    }

    @Test func countsSubagentMarkers() throws {
        _ = try writeSession(id: "busy", state: "working",
                             pid: Int(ProcessInfo.processInfo.processIdentifier))
        try writeAgentMarkers(id: "busy", count: 3)
        #expect(store.activeSessions().first?.agents == 3)
    }

    @Test func sessionWithoutMarkersHasZeroAgents() throws {
        _ = try writeSession(id: "plain", pid: Int(ProcessInfo.processInfo.processIdentifier))
        #expect(store.activeSessions().first?.agents == 0)
    }

    @Test func deadSessionCleanupAlsoRemovesAgentsDir() throws {
        _ = try writeSession(id: "dead", pid: try deadPid())
        try writeAgentMarkers(id: "dead", count: 2)
        _ = store.activeSessions()
        let agentsDir = dir.appendingPathComponent("dead.agents")
        #expect(!FileManager.default.fileExists(atPath: agentsDir.path))
    }

    // MARK: - Background agent titles

    /// Background agent transcripts begin with title lines like
    /// {"type":"agent-name","agentName":"…"} / {"type":"ai-title","aiTitle":"…"}.
    private func writeTranscript(_ lines: [String]) throws -> String {
        let url = dir.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    private func bgSession(id: String, transcript: String?) throws {
        _ = try writeSession(id: id, pid: Int(ProcessInfo.processInfo.processIdentifier),
                             tty: "", transcriptPath: transcript)
    }

    @Test func agentNameBecomesTitle() throws {
        let path = try writeTranscript([
            #"{"type":"ai-title","aiTitle":"older title","sessionId":"x"}"#,
            #"{"type":"agent-name","agentName":"Improve win rate","sessionId":"x"}"#,
            #"{"type":"mode","mode":"normal"}"#,
        ])
        try bgSession(id: "titled", transcript: path)
        #expect(store.activeSessions().first?.title == "Improve win rate")
    }

    @Test func lastAgentNameWins() throws {
        let path = try writeTranscript([
            #"{"type":"agent-name","agentName":"first"}"#,
            #"{"type":"agent-name","agentName":"renamed"}"#,
        ])
        try bgSession(id: "renamed", transcript: path)
        #expect(store.activeSessions().first?.title == "renamed")
    }

    @Test func fallsBackToAiTitle() throws {
        let path = try writeTranscript([#"{"type":"ai-title","aiTitle":"only ai title"}"#])
        try bgSession(id: "ai-only", transcript: path)
        #expect(store.activeSessions().first?.title == "only ai title")
    }

    @Test func noTranscriptMeansNoTitle() throws {
        try bgSession(id: "bare", transcript: nil)
        try bgSession(id: "gone", transcript: dir.appendingPathComponent("missing.jsonl").path)
        for session in store.activeSessions() {
            #expect(session.title == nil)
        }
    }

    @Test func titleRefreshesWhenTranscriptGrows() throws {
        let path = try writeTranscript([#"{"type":"agent-name","agentName":"before"}"#])
        try bgSession(id: "grows", transcript: path)
        #expect(store.activeSessions().first?.title == "before")
        let handle = FileHandle(forWritingAtPath: path)!
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"type\":\"agent-name\",\"agentName\":\"after\"}\n".utf8))
        #expect(store.activeSessions().first?.title == "after")
    }

    @Test func resetRemovesAgentMarkers() throws {
        _ = try writeSession(id: "busy", pid: Int(ProcessInfo.processInfo.processIdentifier))
        try writeAgentMarkers(id: "busy", count: 1)
        store.reset()
        let agentsDir = dir.appendingPathComponent("busy.agents")
        #expect(!FileManager.default.fileExists(atPath: agentsDir.path))
        #expect(store.activeSessions().isEmpty)
    }
}
