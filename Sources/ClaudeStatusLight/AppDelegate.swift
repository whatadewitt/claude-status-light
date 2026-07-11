import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = StateStore()
    private let remote = RemoteStore(config: RelayConfig.load())
    private let statusBar = StatusBarController()
    private let floating = FloatingPanelController()
    private let settingsWindow = SettingsWindowController()

    private var timer: Timer?
    private var dirSource: DispatchSourceFileSystemObject?
    private var danceTimer: Timer?
    private var danceFrame = 0
    private var danceMove: [Int] = []
    private var danceStep = 0

    private var currentSessions: [SessionState] = []
    private var currentState: LightState = .off
    private let dockBackground = NSColor(calibratedWhite: 0.13, alpha: 1)

    func applicationDidFinishLaunching(_ notification: Notification) {
        floating.onFocus = { session in
            guard session.origin == nil else { return }  // nothing to focus locally
            TerminalFocuser.focus(session)
        }
        remote.start()
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
        let sessions = RemoteStore.merge(local: store.activeSessions(), remote: remote.sessions())
        let state = store.aggregate(sessions, greenBeatsYellow: Settings.shared.greenBeatsYellow)
        currentSessions = sessions
        currentState = state

        statusBar.update(state: state, menu: makeMenu()) // no-ops when hidden
        if Settings.shared.showFloatingWindow {
            floating.update(state: state, sessions: sessions)
        }
        updateDance(anyWorking: sessions.contains { $0.state == .working })
        applyIcons()
    }

    // MARK: - Dance

    /// The mascot dances while any session is working — even if the aggregate
    /// light shows another color (e.g. green because a different session is
    /// ready, with "green beats yellow" on). Motion = something is running.
    private func updateDance(anyWorking: Bool) {
        if anyWorking {
            guard danceTimer == nil else { return }
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.danceTick()
            }
            timer.tolerance = 0.1
            danceTimer = timer
        } else {
            danceTimer?.invalidate()
            danceTimer = nil
            danceFrame = 0
            danceMove = []
            danceStep = 0
        }
    }

    /// Advances the choreography: play the current move through, then switch
    /// to a different randomly chosen one.
    private func danceTick() {
        if danceStep >= danceMove.count {
            danceMove = IconRenderer.danceMoves.filter { $0 != danceMove }.randomElement() ?? danceMove
            danceStep = 0
        }
        danceFrame = danceMove[danceStep]
        danceStep += 1
        applyIcons()
    }

    /// Renders the current state + dance frame onto every visible surface.
    private func applyIcons() {
        let agents = currentSessions.reduce(0) { $0 + $1.agents }
        statusBar.setIcon(IconRenderer.icon(for: currentState, side: 18, frame: danceFrame, agents: agents))
        if Settings.shared.showFloatingWindow {
            floating.setIcon(IconRenderer.icon(for: currentState, side: 16, frame: danceFrame, agents: agents))
        }
        if Settings.shared.showDockIcon {
            NSApp.applicationIconImage = IconRenderer.icon(
                for: currentState, side: 128, background: dockBackground, frame: danceFrame, agents: agents)
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
            if currentSessions.contains(where: { $0.origin == nil }) {
                let hint = NSMenuItem(title: "Click a session to open its terminal", action: nil, keyEquivalent: "")
                hint.isEnabled = false
                menu.addItem(hint)
            }
            for session in currentSessions {
                let title = "\(session.state.dot) \(session.displayName)\(session.shellsSuffix) — \(session.state.label)\(session.agentsSuffix)"
                let item: NSMenuItem
                if session.origin == nil {
                    item = NSMenuItem(title: title, action: #selector(ClosureInvoker.fire), keyEquivalent: "")
                    let invoker = ClosureInvoker { TerminalFocuser.focus(session) }
                    item.target = invoker
                    item.representedObject = invoker // retain
                } else {
                    // Remote session — no terminal on this machine to focus.
                    item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                }
                if session.isParked {
                    item.attributedTitle = NSAttributedString(
                        string: item.title,
                        attributes: [
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .font: NSFont.menuFont(ofSize: 0),
                        ])
                }
                item.toolTip = session.tooltip
                menu.addItem(item)
            }
        }

        // Absence of remote rows must be distinguishable from a dead relay.
        if remote.isConfigured && remote.unreachable {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "relay unreachable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
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
