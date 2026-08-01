import AppKit

/// The status a single Claude Code session can report, in priority order.
/// Higher `priority` wins when several sessions are active at once.
enum Status: String, CaseIterable {
    case waiting   // Claude needs your input / a permission — most urgent.
    case working   // A tool is running or Claude is generating.
    case idle      // Turn finished, waiting on your next prompt.
    case none      // No active sessions.

    /// Aggregation priority — the highest wins across all live sessions.
    var priority: Int {
        switch self {
        case .waiting: return 3
        case .working: return 2
        case .idle:    return 1
        case .none:    return 0
        }
    }

    /// The dot color shown in the menu bar.
    var color: NSColor {
        switch self {
        case .waiting: return NSColor.systemRed
        case .working: return NSColor.systemYellow
        case .idle:    return NSColor.systemGreen
        case .none:    return NSColor.tertiaryLabelColor
        }
    }

    /// Human-readable label for the dropdown menu.
    var label: String {
        switch self {
        case .waiting: return "Needs your input"
        case .working: return "Working…"
        case .idle:    return "Idle"
        case .none:    return "No active sessions"
        }
    }

    /// Parse a status written by the hook script. Unknown values -> idle.
    init(hookValue: String) {
        switch hookValue {
        case "waiting": self = .waiting
        case "working": self = .working
        case "idle":    self = .idle
        default:        self = .idle
        }
    }
}
