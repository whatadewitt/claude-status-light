import Foundation

/// One session's reported state, decoded from a `<session>.json` file.
struct SessionState: Decodable {
    let status: String
    let updatedAt: Double
    let sessionId: String
}

/// Reads the per-session state files written by `claude-status.sh` and
/// aggregates them into a single overall `Status`.
final class StatusStore {
    /// Directory holding one JSON file per session.
    /// Keep in sync with `state_dir` in hooks/claude-status.sh.
    let sessionsDir: URL

    /// Sessions whose last update is older than this are treated as dead and
    /// ignored (a crashed session never sends its `end`). 30 minutes is long
    /// enough that a session paused mid-turn isn't dropped prematurely.
    let staleAfter: TimeInterval = 30 * 60

    init() {
        if let override = ProcessInfo.processInfo.environment["CLAUDE_STATUS_LIGHT_DIR"] {
            sessionsDir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            sessionsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/status-light/sessions", isDirectory: true)
        }
    }

    /// A live session and its parsed status.
    struct LiveSession {
        let id: String
        let status: Status
        let updatedAt: Date
    }

    /// All sessions that are still fresh, newest first.
    func liveSessions() -> [LiveSession] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let now = Date()
        var result: [LiveSession] = []
        for url in entries where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let state = try? JSONDecoder().decode(SessionState.self, from: data)
            else { continue }

            let updated = Date(timeIntervalSince1970: state.updatedAt)
            if now.timeIntervalSince(updated) > staleAfter {
                // Best-effort cleanup of an abandoned session file.
                try? fm.removeItem(at: url)
                continue
            }
            result.append(LiveSession(
                id: state.sessionId,
                status: Status(hookValue: state.status),
                updatedAt: updated
            ))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// The single status to display: the highest-priority live session,
    /// or `.none` when nothing is active.
    func overall() -> Status {
        liveSessions().map(\.status).max { $0.priority < $1.priority } ?? .none
    }
}
