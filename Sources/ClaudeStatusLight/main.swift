import AppKit
import Foundation

// MARK: - State model

/// The four light states, in ascending display priority.
/// When multiple Claude Code sessions are active, the highest-priority
/// state wins (attention beats working beats idle).
enum LightState: String {
    case off        // no active session
    case idle       // ready / done, waiting for you
    case working    // running tools / thinking
    case attention  // needs you: permission prompt or notification

    var color: NSColor {
        switch self {
        case .off:       return NSColor.systemGray
        case .idle:      return NSColor.systemGreen
        case .working:   return NSColor.systemBlue
        case .attention: return NSColor.systemYellow
        }
    }

    var label: String {
        switch self {
        case .off:       return "No active session"
        case .idle:      return "Idle — ready for you"
        case .working:   return "Working…"
        case .attention: return "Needs your attention"
        }
    }

    /// Higher wins when aggregating across sessions.
    var priority: Int {
        switch self {
        case .off:       return 0
        case .idle:      return 1
        case .working:   return 2
        case .attention: return 3
        }
    }
}

/// One Claude Code session's reported state.
struct SessionState {
    let sessionID: String
    let state: LightState
    let updatedAt: Date
}

// MARK: - State store

/// Reads the per-session state files that the hook script writes and
/// aggregates them into a single light state.
final class StateStore {
    static let sessionsDir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/status-light/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Sessions untouched for longer than this are considered dead and ignored
    /// (covers the case where Claude Code exits without firing SessionEnd).
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
            result.append(SessionState(sessionID: id, state: state, updatedAt: updatedAt))
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = StateStore()
    private var timer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?

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
        let menu = NSMenu()

        let header = NSMenuItem(title: "Claude Code — \(state.label)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !sessions.isEmpty {
            menu.addItem(.separator())
            for s in sessions {
                let shortID = String(s.sessionID.prefix(8))
                let item = NSMenuItem(
                    title: "  \(dot(for: s.state)) \(shortID) — \(s.state.label)",
                    action: nil,
                    keyEquivalent: ""
                )
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear all sessions", action: #selector(reset), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil { item.target = self }
        return menu
    }

    private func dot(for state: LightState) -> String {
        switch state {
        case .off:       return "⚪️"
        case .idle:      return "🟢"
        case .working:   return "🔵"
        case .attention: return "🟡"
        }
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
        image.isTemplate = false // keep our colors; do not tint to menu-bar template
        return image
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
