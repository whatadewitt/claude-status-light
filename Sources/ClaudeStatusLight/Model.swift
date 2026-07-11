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
    /// Running subagents (one hook marker file each).
    let agents: Int
    /// The session's task title from its transcript (background agents get
    /// an AI-generated one), when the transcript is available and titled.
    let title: String?
    /// Commands of Bash tool shells still running under this session's pid.
    let shells: [String]

    /// Where this session lives: nil = this Mac, else a publisher's host
    /// label or "cloud". Remote sessions can't be PID-checked or focused.
    var origin: String? = nil

    /// Remote sessions carry the publisher's background verdict — their
    /// recorded pid/tty are meaningless on this machine.
    var backgroundOverride: Bool? = nil

    /// Headless sessions (daemon-spawned, background tasks): a known owning
    /// process but no controlling terminal.
    var isBackground: Bool { backgroundOverride ?? (pid != nil && tty.isEmpty) }

    /// Claude Code parks finished background agents instead of exiting them —
    /// alive "awaiting next task" but doing nothing. Quiet headless idle rows
    /// get dimmed so live work keeps the visual weight. Interactive terminals
    /// idling at a prompt are normal, never parked.
    var isParked: Bool {
        isBackground && state == .idle && Date().timeIntervalSince(updatedAt) > 2 * 60
    }

    /// Human label for the menu — the project folder name.
    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "session" : name
    }

    /// Row descriptor shared by the menu and the floating panel so the two
    /// surfaces can't drift. A background session shows what its agent is
    /// working on when the transcript has a title; otherwise it keeps the
    /// bare "(bg)" marker (e.g. pre-warmed spares with no transcript).
    var displayName: String {
        let base: String
        if !isBackground {
            base = project
        } else if var title, !title.isEmpty {
            if title.count > 48 {
                title = title.prefix(47) + "…"
            }
            base = "\(project) · \(title)"
        } else {
            base = "\(project) (bg)"
        }
        guard let origin else { return base }
        return "\(origin) · \(base)"
    }

    /// " · N agent(s)" when subagents are running, empty otherwise.
    var agentsSuffix: String {
        agents > 0 ? " · \(agents) agent\(agents == 1 ? "" : "s")" : ""
    }

    /// What Claude-spawned shell work is still running: the first command
    /// (truncated), with a count when there are several. Full commands are
    /// in the tooltip. Titled agent rows suppress this — the title already
    /// says what the agent is doing; its shells still turn the row yellow.
    var shellsSuffix: String {
        if isBackground && !(title ?? "").isEmpty { return "" }
        guard var cmd = shells.first else { return "" }
        if cmd.count > 40 {
            cmd = cmd.prefix(39) + "…"
        }
        return shells.count == 1 ? " · sh: \(cmd)" : " · \(shells.count) sh: \(cmd)"
    }

    /// Hover detail shared by the menu and the floating panel.
    var tooltip: String {
        var lines = [cwd, "\(termProgram) · \(tty.isEmpty ? "tty unknown" : tty)"]
        if let origin {
            lines.append("remote session on \(origin)")
        } else if isParked {
            let minutes = Int(Date().timeIntervalSince(updatedAt) / 60)
            lines.append("parked — idle \(minutes)m, process alive")
        } else if isBackground {
            lines.append("background session (no terminal)")
        }
        lines.append(contentsOf: shells.map { "sh: \($0.prefix(300))" })
        return lines.joined(separator: "\n")
    }
}
