import AppKit

/// The preferences window: toggles for each surface plus placement options.
final class SettingsWindowController: NSObject {
    private var window: NSWindow?
    private var toggles: [Toggle] = []
    private var pickers: [Picker] = []
    private var invokers: [ClosureInvoker] = []

    /// Invoked when the "Reveal icon folder…" button is pressed.
    var onRevealIcon: (() -> Void)?

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

        let nudgeRow = NSStackView()
        nudgeRow.orientation = .horizontal
        nudgeRow.spacing = 8
        nudgeRow.addArrangedSubview(checkbox("Nudge me before the context cache expires, after", settings.idleNudgeEnabled) {
            Settings.shared.idleNudgeEnabled = $0
        })
        let nudgeMinutes: [Double] = [2, 3, 3.5, 4, 4.5]
        let selectedMinute = nudgeMinutes.firstIndex(of: settings.idleNudgeMinutes) ?? 3
        let nudgePicker = Picker(
            titles: nudgeMinutes.map { $0 == floor($0) ? "\(Int($0)) min" : "\($0) min" },
            selected: selectedMinute
        ) { Settings.shared.idleNudgeMinutes = nudgeMinutes[$0] }
        pickers.append(nudgePicker)
        nudgeRow.addArrangedSubview(nudgePicker.popup)
        stack.addArrangedSubview(nudgeRow)

        let nudgeHint = NSTextField(wrappingLabelWithString:
            "Notifies you when an interactive session has been waiting on you "
            + "(green or red) that long, so you can reply before the ~5-minute "
            + "prompt cache goes cold. One nudge per idle stretch.")
        nudgeHint.font = .systemFont(ofSize: 11)
        nudgeHint.textColor = .secondaryLabelColor
        nudgeHint.preferredMaxLayoutWidth = 340
        stack.addArrangedSubview(nudgeHint)

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
}
