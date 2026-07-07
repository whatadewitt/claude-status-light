import AppKit

/// Stoplight states.
enum LightState: String {
    case off        // not running — no active session
    case working    // running — tools / thinking
    case idle       // awaiting your next task (done)
    case attention  // waiting for your input — permission prompt / notification

    var color: NSColor {
        switch self {
        case .off:       return NSColor.systemGray
        case .working:   return NSColor.systemYellow
        case .idle:      return NSColor.systemGreen
        case .attention: return NSColor.systemRed
        }
    }

    var label: String {
        switch self {
        case .off:       return "Not running"
        case .working:   return "Running…"
        case .idle:      return "Awaiting next task"
        case .attention: return "Waiting for input"
        }
    }

    var dot: String {
        switch self {
        case .off:       return "⚪️"
        case .working:   return "🟡"
        case .idle:      return "🟢"
        case .attention: return "🔴"
        }
    }
}

/// One Claude Code session's reported state.
struct SessionState {
    let sessionID: String
    let state: LightState
    let cwd: String
    let termProgram: String
    let tty: String
    /// PID of the Claude Code process, when the hook could identify it.
    let pid: Int?
    let updatedAt: Date

    /// Headless sessions (daemon-spawned, background tasks): a known owning
    /// process but no controlling terminal.
    var isBackground: Bool { pid != nil && tty.isEmpty }

    /// Human label for the menu — the project folder name.
    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "session" : name
    }
}
