import AppKit

/// The preferences window: toggles for each surface plus placement options.
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private var toggles: [Toggle] = []
    private var pickers: [Picker] = []
    private var invokers: [ClosureInvoker] = []

    /// Invoked when the "Reveal icon folder…" button is pressed.
    var onRevealIcon: (() -> Void)?
    /// Invoked after a successful deploy so the app reloads relay polling.
    var onRelayChanged: (() -> Void)?
    private var relayStatus: NSTextField?
    private var relayButton: NSButton?
    private var deployTask: Task<Void, Never>?
    /// Retains the presented sheet — the deploy task finishes long before the
    /// user clicks Close, and a deallocated sheet can't dismiss its window.
    private var activeSheet: DeployProgressSheet?

    func show() {
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let settings = Settings.shared
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(sectionLabel("Surfaces"))
        stack.addArrangedSubview(checkbox("Show menu bar icon", settings.showMenuBar) {
            Settings.shared.showMenuBar = $0
        })
        stack.addArrangedSubview(checkbox("Show floating desktop window", settings.showFloatingWindow) {
            Settings.shared.showFloatingWindow = $0
        })
        stack.addArrangedSubview(checkbox("Show dock icon", settings.showDockIcon) {
            Settings.shared.showDockIcon = $0
        })

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel("Floating window"))

        let cornerRow = NSStackView()
        cornerRow.orientation = .horizontal
        cornerRow.spacing = 8
        cornerRow.addArrangedSubview(checkbox("Lock to corner", settings.lockToCorner) {
            Settings.shared.lockToCorner = $0
        })
        let picker = Picker(
            titles: ScreenCorner.allCases.map { $0.label },
            selected: settings.corner.rawValue
        ) { Settings.shared.corner = ScreenCorner(rawValue: $0) ?? .topRight }
        pickers.append(picker)
        cornerRow.addArrangedSubview(picker.popup)
        stack.addArrangedSubview(cornerRow)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel("Behavior"))
        stack.addArrangedSubview(checkbox("“Awaiting task” (green) outranks “running” (yellow)", settings.greenBeatsYellow) {
            Settings.shared.greenBeatsYellow = $0
        })

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel("Icon"))
        let hint = NSTextField(wrappingLabelWithString:
            "Drop an image at ~/.claude/status-light/icon.png (e.g. the Claude mascot) "
            + "to use it as the icon — a colored status dot is added automatically.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 340
        stack.addArrangedSubview(hint)

        let reveal = NSButton(title: "Reveal icon folder…", target: nil, action: nil)
        reveal.bezelStyle = .rounded
        let invoker = ClosureInvoker { [weak self] in self?.onRevealIcon?() }
        reveal.target = invoker
        reveal.action = #selector(ClosureInvoker.fire)
        invokers.append(invoker)
        stack.addArrangedSubview(reveal)

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(sectionLabel("Remote sessions"))
        let relayConfig = RelayConfig.load()
        let status = NSTextField(labelWithString: Self.relayStatusText(config: relayConfig))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        relayStatus = status
        stack.addArrangedSubview(status)

        let deploy = NSButton(title: Self.relayButtonTitle(config: relayConfig), target: nil, action: nil)
        deploy.bezelStyle = .rounded
        let deployInvoker = ClosureInvoker { [weak self] in self?.runDeploy() }
        deploy.target = deployInvoker
        deploy.action = #selector(ClosureInvoker.fire)
        invokers.append(deployInvoker)
        relayButton = deploy
        stack.addArrangedSubview(deploy)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Claude Status Light"
        window.isReleasedWhenClosed = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setContentSize(stack.fittingSize)
        self.window = window
    }

    private func checkbox(_ title: String, _ value: Bool, _ onChange: @escaping (Bool) -> Void) -> NSButton {
        let toggle = Toggle(title: title, value: value, onChange: onChange)
        toggles.append(toggle)
        return toggle.button
    }

    private func sectionLabel(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .boldSystemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    static func relayStatusText(config: RelayConfig?) -> String {
        config.map { "relay: \($0.url.absoluteString)" } ?? "not set up"
    }

    static func relayButtonTitle(config: RelayConfig?) -> String {
        config == nil ? "Set up Cloudflare relay…" : "Re-deploy relay…"
    }

    private func runDeploy() {
        // AppKit target/action always fires on the main thread, but this
        // class isn't itself @MainActor-isolated — assert what's already
        // true so the (deliberately isolated) DeployProgressSheet can be
        // constructed here without an `await`.
        MainActor.assumeIsolated {
            guard deployTask == nil, let window else { return }
            let sheet = DeployProgressSheet()
            // Retain until dismissed: the deploy task (the only other strong
            // reference) ends well before the user clicks Close, and the
            // button must stay disabled while the sheet is still up.
            activeSheet = sheet
            window.beginSheet(sheet.window) { [weak self] _ in
                self?.activeSheet = nil
                self?.relayButton?.isEnabled = true
            }
            relayButton?.isEnabled = false
            sheet.onCancel = { [weak self] in self?.deployTask?.cancel() }

            deployTask = Task { @MainActor [weak self] in
                defer { self?.deployTask = nil }
                do {
                    sheet.begin("Logging in")
                    let token = try await CloudflareAuth().accessToken()
                    let deployer = CloudflareDeployer { accounts in
                        await sheet.pickAccount(from: accounts)
                    }
                    let config = try await deployer.deploy(accessToken: token,
                                                           existing: RelayConfig.load()) { step in
                        sheet.begin(step.label)
                    }
                    sheet.finish("Done — \(config.url.absoluteString)")
                    self?.relayStatus?.stringValue = Self.relayStatusText(config: config)
                    self?.relayButton?.title = Self.relayButtonTitle(config: config)
                    self?.onRelayChanged?()
                } catch is CancellationError {
                    // The user already dismissed the sheet; leave it alone.
                } catch {
                    sheet.fail(error.localizedDescription)
                }
            }
        }
    }
}

/// Modal sheet that streams deploy steps: each `begin` checks off the
/// previous line, `fail` pins the error and offers the CLI fallback.
@MainActor
final class DeployProgressSheet {
    let window: NSWindow
    private let log = NSTextField(wrappingLabelWithString: "")
    private let close = NSButton(title: "Cancel", target: nil, action: nil)
    private var lines: [String] = []
    private var invokers: [ClosureInvoker] = []
    private var indexChoice: CheckedContinuation<Int, Never>?
    private let accountPopup = NSPopUpButton()
    private let accountRow = NSStackView()
    /// Invoked when the user dismisses the sheet before it finished or
    /// failed on its own — the caller cancels the in-flight deploy task.
    var onCancel: (() -> Void)?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Cloudflare relay"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        log.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        log.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(log)

        accountRow.orientation = .horizontal
        accountRow.spacing = 8
        accountRow.addArrangedSubview(NSTextField(labelWithString: "Account:"))
        accountRow.addArrangedSubview(accountPopup)
        let choose = NSButton(title: "Use this account", target: nil, action: nil)
        choose.bezelStyle = .rounded
        let chooseInvoker = ClosureInvoker { [weak self] in self?.confirmAccount() }
        choose.target = chooseInvoker
        choose.action = #selector(ClosureInvoker.fire)
        invokers.append(chooseInvoker)
        accountRow.addArrangedSubview(choose)
        accountRow.isHidden = true
        stack.addArrangedSubview(accountRow)

        close.bezelStyle = .rounded
        stack.addArrangedSubview(close)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 400),
        ])
        window.contentView = content
        let closeInvoker = ClosureInvoker { [weak self] in self?.dismiss() }
        close.target = closeInvoker
        close.action = #selector(ClosureInvoker.fire)
        invokers.append(closeInvoker)
    }

    func begin(_ step: String) {
        if var last = lines.last, last.hasSuffix("…") {
            last.removeLast()
            lines[lines.count - 1] = "✓ " + last
        }
        lines.append(step + "…")
        render()
    }

    func finish(_ message: String) {
        begin(message)  // checks off the last step
        lines[lines.count - 1] = "✓ " + message
        close.title = "Close"
        close.isEnabled = true
        render()
    }

    func fail(_ message: String) {
        lines.append("✗ " + message)
        lines.append("CLI alternative: scripts/deploy-relay.sh")
        close.title = "Close"
        close.isEnabled = true
        render()
    }

    func pickAccount(from accounts: [CFAccount]) async -> CFAccount {
        accountPopup.removeAllItems()
        for account in accounts {
            accountPopup.menu?.addItem(NSMenuItem(title: account.name, action: nil, keyEquivalent: ""))
        }
        accountRow.isHidden = false
        render()
        let chosen = await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
            indexChoice = cont
        }
        accountRow.isHidden = true
        return accounts[chosen]
    }

    private func confirmAccount() {
        indexChoice?.resume(returning: max(0, accountPopup.indexOfSelectedItem))
        indexChoice = nil
    }

    private func dismiss() {
        onCancel?()
        window.sheetParent?.endSheet(window)
    }

    private func render() {
        log.stringValue = lines.joined(separator: "\n")
        window.setContentSize(window.contentView!.fittingSize)
    }
}
