import Foundation

/// Reads the per-session state files the hook writes and aggregates them.
final class StateStore {
    static let sessionsDir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/status-light/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Sessions without a recorded PID that are untouched for longer than this
    /// are treated as dead and ignored (covers old-format files and hooks that
    /// couldn't identify their Claude process).
    private let staleAfter: TimeInterval = 12 * 60 * 60

    private let dir: URL

    init(sessionsDir: URL = StateStore.sessionsDir) {
        self.dir = sessionsDir
    }

    func activeSessions() -> [SessionState] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return [] }

        let now = Date()
        var result: [SessionState] = []
        for url in files where url.pathExtension == "json" {
            guard
                let data = try? Data(contentsOf: url),
                let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let stateRaw = obj["state"] as? String,
                let state = LightState(rawValue: stateRaw)
            else { continue }

            let updatedAt: Date
            if let ts = obj["updated_at"] as? Double {
                updatedAt = Date(timeIntervalSince1970: ts)
            } else if let ts = obj["updated_at"] as? String, let d = Double(ts) {
                updatedAt = Date(timeIntervalSince1970: d)
            } else {
                updatedAt = now
            }

            // The hook writes 0 when it can't identify its Claude process;
            // treat that (and anything non-signalable) as "unknown".
            let pid = (obj["pid"] as? Int).flatMap { $0 > 1 ? $0 : nil }

            if let pid {
                // Owning process gone → the session is over; clean up the file
                // (covers Claude Code dying without firing SessionEnd).
                if kill(pid_t(pid), 0) != 0 && errno == ESRCH {
                    try? fm.removeItem(at: url)
                    continue
                }
            } else if now.timeIntervalSince(updatedAt) > staleAfter {
                continue
            }

            let id = (obj["session_id"] as? String) ?? url.deletingPathExtension().lastPathComponent
            result.append(SessionState(
                sessionID: id,
                state: state,
                cwd: (obj["cwd"] as? String) ?? "",
                termProgram: (obj["term_program"] as? String) ?? "unknown",
                tty: (obj["tty"] as? String) ?? "",
                pid: pid,
                updatedAt: updatedAt
            ))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Highest-priority state across sessions. Red (blocked on you) always wins;
    /// `greenBeatsYellow` decides whether "done, awaiting a task" outranks "busy".
    func aggregate(_ sessions: [SessionState], greenBeatsYellow: Bool) -> LightState {
        func priority(_ s: LightState) -> Int {
            switch s {
            case .off:       return 0
            case .working:   return greenBeatsYellow ? 1 : 2
            case .idle:      return greenBeatsYellow ? 2 : 1
            case .attention: return 3
            }
        }
        return sessions.map(\.state).max(by: { priority($0) < priority($1) }) ?? .off
    }

    func reset() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in files where url.pathExtension == "json" {
            try? fm.removeItem(at: url)
        }
    }
}
