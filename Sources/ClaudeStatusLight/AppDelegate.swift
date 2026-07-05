import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StateStore()
    private let statusBar = StatusBarController()
    private let floating = FloatingPanelController()
    private let settingsWindow = SettingsWindowController()

    private var timer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?

    private var currentSessions: [SessionState] = []
    private var currentState: LightState = .off
    private let dockBackground = NSColor(calibratedWhite: 0.13, alpha: 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        floating.onFocus = { TerminalFocuser.focus($0) }
        floating.onRequestMenu = { [weak self] in self?.makeMenu() ?? NSMenu() }
        settingsWindow.onRevealIcon = { [weak self] in self?.revealIconFolder() }

        NotificationCenter.default.addObserver(
            self, selector: #selector(applySettings),
            name: .statusLightSettingsChanged, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(refresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        applySettings()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        startWatching()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { makeMenu() }

    // MARK: - Settings

    @objc private func applySettings() {
        let settings = Settings.shared

        // Never leave the app with no way to reach it: if the user disables
        // every surface, keep the menu bar icon.
        var menuBar = settings.showMenuBar
        if !menuBar && !settings.showFloatingWindow && !settings.showDockIcon {
            menuBar = true
        }

        statusBar.setVisible(menuBar)
        floating.setVisible(settings.showFloatingWindow)
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        if !settings.showDockIcon {
            NSApp.applicationIconImage = nil
        }
        refresh()
    }

    // MARK: - Refresh

    @objc private func refresh() {
        let sessions = store.activeSessions()
        let state = store.aggregate(sessions, greenBeatsYellow: Settings.shared.greenBeatsYellow)
        currentSessions = sessions
        currentState = state

        statusBar.update(state: state, menu: makeMenu()) // no-ops when hidden
        if Settings.shared.showFloatingWindow {
            floating.update(state: state, sessions: sessions)
        }
        if Settings.shared.showDockIcon {
            NSApp.applicationIconImage = IconRenderer.icon(for: state, side: 128, background: dockBackground)
        }
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

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let header = NSMenuItem(title: "Claude Code — \(currentState.label)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if !currentSessions.isEmpty {
            menu.addItem(.separator())
            let hint = NSMenuItem(title: "Click a session to open its terminal", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
            for session in currentSessions {
                let item = NSMenuItem(
                    title: "\(session.state.dot) \(session.project) — \(session.state.label)",
                    action: #selector(ClosureInvoker.fire), keyEquivalent: ""
                )
                let invoker = ClosureInvoker { TerminalFocuser.focus(session) }
                item.target = invoker
                item.representedObject = invoker // retain
                item.toolTip = "\(session.cwd)\n\(session.termProgram) · \(session.tty.isEmpty ? "tty unknown" : session.tty)"
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addItem(to: menu, title: "Set custom icon…", key: "") { [weak self] in self?.revealIconFolder() }
        addItem(to: menu, title: "Settings…", key: ",") { [weak self] in self?.settingsWindow.show() }
        addItem(to: menu, title: "Clear all sessions", key: "") { [weak self] in
            self?.store.reset()
            self?.refresh()
        }
        addItem(to: menu, title: "Quit", key: "q") { NSApp.terminate(nil) }
        return menu
    }

    /// Opens ~/.claude/status-light in Finder so a custom icon.png can be dropped
    /// in, selecting the existing icon if there is one.
    private func revealIconFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/status-light", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let icon = dir.appendingPathComponent("icon.png")
        if FileManager.default.fileExists(atPath: icon.path) {
            NSWorkspace.shared.activateFileViewerSelecting([icon])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    private func addItem(to menu: NSMenu, title: String, key: String, _ block: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(ClosureInvoker.fire), keyEquivalent: key)
        let invoker = ClosureInvoker(block)
        item.target = invoker
        item.representedObject = invoker // retain
        menu.addItem(item)
    }
}
