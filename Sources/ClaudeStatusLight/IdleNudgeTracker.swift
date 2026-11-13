import Foundation

/// Decides when a session has sat waiting on you ("ball in your court":
/// green awaiting-task or red waiting-for-input) long enough to nudge.
///
/// One nudge per waiting episode; an episode ends (and re-arms) when the
/// session goes back to work, ends, or stops qualifying. The episode clock
/// starts when the tracker first sees the session waiting, not from the state
/// file's `updated_at` — Claude Code's ~60s idle reminder rewrites that
/// timestamp without an API call, so it says nothing about the prompt cache.
///
/// Only sessions on this Mac with a terminal qualify: background agents never
/// nudge, and remote (relay) sessions are skipped because their tty belongs
/// to another machine, so a click couldn't focus the right tab here.
///
/// Sessions already waiting when watching starts (app launch, or the setting
/// being switched on) are treated as already nudged — they've usually been
/// sitting far longer than the cache lives, and a burst of banners for them
/// isn't useful. Their next episode nudges normally.
struct IdleNudgeTracker {
    private var since: [String: Date] = [:]
    private var nudged: Set<String> = []
    private var watching = false

    static func qualifies(_ s: SessionState) -> Bool {
        (s.state == .idle || s.state == .attention) && !s.isBackground && s.origin == nil
    }

    /// Feed the current session list; returns the sessions to nudge now.
    mutating func update(_ sessions: [SessionState], now: Date,
                         enabled: Bool, threshold: TimeInterval) -> [SessionState] {
        guard enabled else {
            since.removeAll()
            nudged.removeAll()
            watching = false
            return []
        }

        let waiting = sessions.filter(Self.qualifies)
        let waitingIDs = Set(waiting.map(\.sessionID))

        // Episodes that ended re-arm.
        for id in since.keys where !waitingIDs.contains(id) {
            since.removeValue(forKey: id)
            nudged.remove(id)
        }

        if !watching {
            watching = true
            for s in waiting {
                since[s.sessionID] = now
                nudged.insert(s.sessionID)
            }
            return []
        }

        var due: [SessionState] = []
        for s in waiting {
            let start = since[s.sessionID] ?? now
            since[s.sessionID] = start
            if !nudged.contains(s.sessionID), now.timeIntervalSince(start) >= threshold {
                nudged.insert(s.sessionID)
                due.append(s)
            }
        }
        return due
    }
}
