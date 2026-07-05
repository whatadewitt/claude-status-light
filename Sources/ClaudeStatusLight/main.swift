import AppKit
import Foundation

// MARK: - State model

/// Stoplight states, in ascending display priority.
/// When multiple Claude Code sessions are active, the highest-priority state
/// wins the single menu-bar light (waiting-for-input beats awaiting-next-task
/// beats running — the click-through menu shows each session individually).
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

    /// Higher wins when aggregating across sessions.
    /// Red (blocked on you) ▸ green (done, wants a task) ▸ yellow (busy) ▸ off.
    var priority: Int {
        switch self {
        case .off:       return 0
        case .working:   return 1
        case .idle:      return 2
        case .attention: return 3
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
    let updatedAt: Date

    /// Human label for the menu — the project folder name.
    var project: String {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty ? "session" : name
    }
}

// MARK: - State store

/// Reads the per-session state files the hook writes and aggregates them.
final class StateStore {
    static let sessionsDir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/status-light/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Sessions untouched for longer than this are treated as dead and ignored
    /// (covers Claude Code exiting without firing SessionEnd).
    private let staleAfter: TimeInterval = 12 * 60 * 60

    func activeSessions() -> [SessionState] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.sessionsDir,
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
            if now.timeIntervalSince(updatedAt) > staleAfter { continue }

            let id = (obj["session_id"] as? String) ?? url.deletingPathExtension().lastPathComponent
            result.append(SessionState(
                sessionID: id,
                state: state,
                cwd: (obj["cwd"] as? String) ?? "",
                termProgram: (obj["term_program"] as? String) ?? "unknown",
                tty: (obj["tty"] as? String) ?? "",
                updatedAt: updatedAt
            ))
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    func aggregate(_ sessions: [SessionState]) -> LightState {
        sessions.map(\.state).max(by: { $0.priority < $1.priority }) ?? .off
    }

    func reset() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: Self.sessionsDir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in files where url.pathExtension == "json" {
            try? fm.removeItem(at: url)
        }
    }
}

// MARK: - Terminal focusing

/// Brings the terminal window/tab that hosts a given session to the front.
enum TerminalFocuser {
    static func focus(_ s: SessionState) {
        // With a known tty we can target the exact tab; otherwise just raise the app.
        if !s.tty.isEmpty, let script = script(for: s.termProgram, tty: s.tty) {
            runAppleScript(script)
        } else {
            activateApp(for: s.termProgram)
        }
    }

    private static func script(for termProgram: String, tty: String) -> String? {
        let tty = tty.replacingOccurrences(of: "\"", with: "")
        switch termProgram {
        case "Apple_Terminal":
            return """
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (tty of t) is "\(tty)" then
                                set selected of t to true
                                set frontmost of w to true
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            """
        case "iTerm.app":
            return """
            tell application "iTerm"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if (tty of s) is "\(tty)" then
                                    select w
                                    select t
                                    select s
                                    return
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            return nil
        }
    }

    /// Best-effort fallback for terminals we can't target by tty.
    private static func activateApp(for termProgram: String) {
        let appName: String?
        switch termProgram {
        case "Apple_Terminal": appName = "Terminal"
        case "iTerm.app":      appName = "iTerm"
        case "vscode":         appName = "Visual Studio Code"
        case "WezTerm":        appName = "WezTerm"
        case "Hyper":          appName = "Hyper"
        case "Tabby":          appName = "Tabby"
        case "ghostty":        appName = "Ghostty"
        default:               appName = nil
        }
        guard let appName else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", appName]
        try? proc.run()
    }

    private static func runAppleScript(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
            proc.waitUntilExit()
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = StateStore()
    private var timer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var menuSessions: [SessionState] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only agent: no dock icon, no app-switcher entry.
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly

        refresh()

        // Poll as a reliable baseline…
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        // …and watch the directory for near-instant updates.
        startWatching()
    }

    private func startWatching() {
        let fd = open(StateStore.sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        dirSource = source
    }

    private func refresh() {
        let sessions = store.activeSessions()
        let state = store.aggregate(sessions)

        statusItem.button?.image = Self.circleImage(color: state.color)
        statusItem.button?.toolTip = "Claude Code: \(state.label)"
        statusItem.menu = buildMenu(state: state, sessions: sessions)
    }

    private func buildMenu(state: LightState, sessions: [SessionState]) -> NSMenu {
        menuSessions = sessions
        let menu = NSMenu()

        let header = NSMenuItem(title: "Claude Code — \(state.label)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !sessions.isEmpty {
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "Click a session to open its terminal", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)

            for (index, s) in sessions.enumerated() {
                let item = NSMenuItem(
                    title: "\(s.state.dot) \(s.project) — \(s.state.label)",
                    action: #selector(focusSession(_:)),
                    keyEquivalent: ""
                )
                item.tag = index
                item.toolTip = "\(s.cwd)\n\(s.termProgram) · \(s.tty.isEmpty ? "tty unknown" : s.tty)"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear all sessions", action: #selector(reset), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    @objc private func focusSession(_ sender: NSMenuItem) {
        guard menuSessions.indices.contains(sender.tag) else { return }
        TerminalFocuser.focus(menuSessions[sender.tag])
    }

    @objc private func reset() {
        store.reset()
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func circleImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(x: 3, y: 3, width: 10, height: 10)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        image.unlockFocus()
        image.isTemplate = false // keep our colors; do not tint as a template
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
