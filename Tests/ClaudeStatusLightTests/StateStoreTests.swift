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
        age: TimeInterval = 0
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
}
