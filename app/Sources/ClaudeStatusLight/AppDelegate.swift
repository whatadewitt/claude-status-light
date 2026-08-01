import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = StatusStore()
    private var timer: Timer?
    private var lastStatus: Status?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly

        refresh(force: true)

        // Poll the state directory. A status light doesn't need sub-second
        // latency; 1s keeps it responsive while costing almost nothing.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh(force: false)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Re-read state and update the icon + menu. Skips redraw when unchanged
    /// unless `force` is set.
    private func refresh(force: Bool) {
        let sessions = store.liveSessions()
        let status = sessions.map(\.status).max { $0.priority < $1.priority } ?? .none

        if force || status != lastStatus {
            statusItem.button?.image = Self.dotImage(color: status.color)
            statusItem.button?.toolTip = "Claude Code — \(status.label)"
            lastStatus = status
        }
        rebuildMenu(status: status, sessions: sessions)
    }

    private func rebuildMenu(status: Status, sessions: [StatusStore.LiveSession]) {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Claude Code — \(status.label)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No active sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let count = NSMenuItem(
                title: "\(sessions.count) active session\(sessions.count == 1 ? "" : "s")",
                action: nil, keyEquivalent: ""
            )
            count.isEnabled = false
            menu.addItem(count)
            for s in sessions {
                let shortId = String(s.id.prefix(8))
                let item = NSMenuItem(title: "  \(s.status.label) · \(shortId)", action: nil, keyEquivalent: "")
                item.image = Self.dotImage(color: s.status.color, size: 10)
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    /// A filled colored circle sized for the menu bar. Non-template so the
    /// color is preserved (template images render monochrome).
    static func dotImage(color: NSColor, size: CGFloat = 13) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let inset: CGFloat = 1
        let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
