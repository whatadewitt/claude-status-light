import Cocoa

// MARK: - State model

/// The states the light can show. Each maps to a color and a menu label.
enum LightState: String {
    case idle
    case working
    case attention
    case error
    case unknown

    /// Parse a raw string from the state file, tolerating unknown values.
    init(raw: String) {
        self = LightState(rawValue: raw.lowercased()) ?? .unknown
    }

    var color: NSColor {
        switch self {
        case .idle:      return NSColor.systemGreen
        case .working:   return NSColor.systemYellow
        case .attention: return NSColor.systemRed
        case .error:     return NSColor.systemOrange
        case .unknown:   return NSColor.systemGray
        }
    }

    var label: String {
        switch self {
        case .idle:      return "Idle — ready"
        case .working:   return "Working…"
        case .attention: return "Needs your attention"
        case .error:     return "Error"
        case .unknown:   return "No recent activity"
        }
    }

    /// Only "attention" pulses, to draw the eye when Claude is waiting on you.
    var pulses: Bool { self == .attention }
}

/// A snapshot decoded from the state file.
struct StatusSnapshot {
    var state: LightState
    var message: String
    var updated: String

    static let empty = StatusSnapshot(state: .unknown, message: "", updated: "")
}

// MARK: - State file location

/// `~/.claude/status-light/state.json`, written by the `claude-status` helper
/// from Claude Code hooks. Honors CLAUDE_STATUS_FILE for testing/overrides.
func stateFilePath() -> String {
    if let override = ProcessInfo.processInfo.environment["CLAUDE_STATUS_FILE"], !override.isEmpty {
        return (override as NSString).expandingTildeInPath
    }
    let dir = ("~/.claude/status-light" as NSString).expandingTildeInPath
    return dir + "/state.json"
}

// MARK: - App

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var pollTimer: Timer?
    private var pulseTimer: Timer?
    private var pulseOn = true

    private var snapshot = StatusSnapshot.empty

    // Menu items we update in place.
    private let stateMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        refresh()

        // Poll the state file. A half-second cadence feels instant without
        // any measurable cost, and sidesteps the fiddliness of file watchers.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // Drive the pulse animation for the attention state.
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.tickPulse()
        }
    }

    // MARK: Menu

    private func buildMenu() {
        let menu = NSMenu()
        stateMenuItem.isEnabled = false
        detailMenuItem.isEnabled = false
        updatedMenuItem.isEnabled = false

        menu.addItem(stateMenuItem)
        menu.addItem(detailMenuItem)
        menu.addItem(updatedMenuItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Status Light", action: #selector(quit), keyEquivalent: "q"))

        // Targets default to the first responder; wire them to self explicitly.
        for item in menu.items where item.action != nil {
            item.target = self
        }
        statusItem.menu = menu
    }

    @objc private func refreshNow() { refresh() }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: Refresh

    private func refresh() {
        let new = readSnapshot()
        let stateChanged = new.state != snapshot.state
        snapshot = new

        if stateChanged {
            // Reset pulse so a new attention state starts visible.
            pulseOn = true
        }
        render()
    }

    private func readSnapshot() -> StatusSnapshot {
        let path = stateFilePath()
        guard let data = FileManager.default.contents(atPath: path) else {
            return StatusSnapshot.empty
        }
        guard
            let obj = try? JSONSerialization.jsonObject(with: data),
            let dict = obj as? [String: Any]
        else {
            return StatusSnapshot.empty
        }
        let stateRaw = (dict["state"] as? String) ?? "unknown"
        let message = (dict["message"] as? String) ?? ""
        let updated = (dict["updated"] as? String) ?? ""
        return StatusSnapshot(state: LightState(raw: stateRaw), message: message, updated: updated)
    }

    // MARK: Rendering

    private func render() {
        let visible = snapshot.state.pulses ? pulseOn : true
        statusItem.button?.image = dotImage(color: snapshot.state.color, filled: visible)
        statusItem.button?.toolTip = "Claude Code: \(snapshot.state.label)"

        stateMenuItem.title = "● \(snapshot.state.label)"
        stateMenuItem.attributedTitle = coloredTitle("● ", color: snapshot.state.color, suffix: snapshot.state.label)

        detailMenuItem.title = snapshot.message.isEmpty ? "" : snapshot.message
        detailMenuItem.isHidden = snapshot.message.isEmpty

        updatedMenuItem.title = snapshot.updated.isEmpty ? "" : "Updated \(prettyUpdated(snapshot.updated))"
        updatedMenuItem.isHidden = snapshot.updated.isEmpty
    }

    private func tickPulse() {
        guard snapshot.state.pulses else { return }
        pulseOn.toggle()
        render()
    }

    /// Draw a template-friendly colored circle for the menu bar.
    private func dotImage(color: NSColor, filled: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(x: 3, y: 3, width: 10, height: 10)
        let path = NSBezierPath(ovalIn: rect)
        if filled {
            color.setFill()
            path.fill()
        } else {
            // Dim ring during the "off" pulse frame.
            color.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1.5
            path.stroke()
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func coloredTitle(_ prefix: String, color: NSColor, suffix: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: prefix,
            attributes: [.foregroundColor: color]
        )
        result.append(NSAttributedString(string: suffix))
        return result
    }

    /// Turn an ISO-8601 timestamp into a short relative string.
    private func prettyUpdated(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(seconds)s ago" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        return "\(seconds / 3600)h ago"
    }
}

// MARK: - Entry point

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar only, no dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
