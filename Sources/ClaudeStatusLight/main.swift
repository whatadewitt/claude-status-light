import AppKit

// MARK: - State model

/// The states the light can display. Unknown/missing values fall back to `.idle`.
enum ClaudeState: String {
    case idle
    case working
    case waiting
    case error

    var color: NSColor {
        switch self {
        case .idle:    return NSColor.systemGray
        case .working: return NSColor.systemBlue
        case .waiting: return NSColor.systemGreen
        case .error:   return NSColor.systemRed
        }
    }

    var label: String {
        switch self {
        case .idle:    return "Idle"
        case .working: return "Working…"
        case .waiting: return "Waiting for you"
        case .error:   return "Error"
        }
    }

    /// Only `working` pulses, to signal ongoing activity.
    var pulses: Bool { self == .working }
}

/// Shape of `~/.claude/status-light.json`, written by the hook script.
struct StatusPayload: Decodable {
    let state: String
    let detail: String?
    let cwd: String?
    let ts: Double?
}

// MARK: - Controller

final class StatusController: NSObject {

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let stateFileURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/status-light.json")
    }()

    private var state: ClaudeState = .idle
    private var detail: String = ""
    private var cwd: String = ""

    private var lastModified: Date?
    private var pollTimer: Timer?
    private var pulseTimer: Timer?
    private var pulsePhase: CGFloat = 0

    func start() {
        readState()          // pick up any existing state on launch
        render()
        // Poll for changes. The hook writes atomically (mv), so we never see a
        // half-written file; a 0.4s cadence is instant to the eye and cheap.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    // MARK: Reading

    private func tick() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: stateFileURL.path),
              let modified = attrs[.modificationDate] as? Date else {
            // File missing → treat as idle.
            if state != .idle {
                state = .idle; detail = ""; cwd = ""
                render()
            }
            lastModified = nil
            return
        }
        if modified != lastModified {
            lastModified = modified
            readState()
            render()
        }
    }

    private func readState() {
        guard let data = try? Data(contentsOf: stateFileURL),
              let payload = try? JSONDecoder().decode(StatusPayload.self, from: data) else {
            return
        }
        state = ClaudeState(rawValue: payload.state) ?? .idle
        detail = payload.detail ?? ""
        cwd = payload.cwd ?? ""
    }

    // MARK: Rendering

    private func render() {
        updatePulseTimer()
        updateButtonImage()
        statusItem.menu = buildMenu()
    }

    private func updatePulseTimer() {
        if state.pulses {
            guard pulseTimer == nil else { return }
            pulsePhase = 0
            pulseTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.pulsePhase += (1.0 / 30.0)
                self.updateButtonImage()
            }
        } else {
            pulseTimer?.invalidate()
            pulseTimer = nil
            pulsePhase = 0
        }
    }

    private func updateButtonImage() {
        guard let button = statusItem.button else { return }
        var alpha: CGFloat = 1.0
        if state.pulses {
            // Smooth 0.45→1.0 breathing over a ~1.6s cycle.
            let cycle = sin(pulsePhase * (.pi * 2 / 1.6))
            alpha = 0.45 + 0.55 * ((cycle + 1) / 2)
        }
        button.image = Self.dotImage(color: state.color, alpha: alpha)
        button.toolTip = "Claude: \(state.label)"
    }

    private static func dotImage(color: NSColor, diameter: CGFloat = 11, alpha: CGFloat = 1) -> NSImage {
        let padding: CGFloat = 2
        let size = NSSize(width: diameter + padding * 2, height: diameter + padding * 2)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(x: padding, y: padding, width: diameter, height: diameter)
        color.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: rect).fill()
        image.unlockFocus()
        image.isTemplate = false   // keep our color; don't let the menu bar recolor it
        return image
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Claude: \(state.label)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !detail.isEmpty {
            let item = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        if !cwd.isEmpty {
            let pretty = (cwd as NSString).abbreviatingWithTildeInPath
            let item = NSMenuItem(title: "📂 \(pretty)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - App bootstrap

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = StatusController()
    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.start()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
