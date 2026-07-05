import AppKit

/// A small always-on-top desktop panel that mirrors the status and lists
/// active sessions. Can be locked to a screen corner or dragged freely.
final class FloatingPanelController: NSObject {
    private var panel: NSPanel?
    private let container = NSStackView()
    private var invokers: [ClosureInvoker] = []

    /// Called when a listed session is clicked.
    var onFocus: ((SessionState) -> Void)?
    /// Supplies the right-click context menu.
    var onRequestMenu: (() -> NSMenu)?

    func setVisible(_ visible: Bool) {
        if visible {
            if panel == nil { build() }
            panel?.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    private func build() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        container.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(container)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            container.topAnchor.constraint(equalTo: effect.topAnchor),
            container.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        panel.contentView = effect
        self.panel = panel

        NotificationCenter.default.addObserver(
            self, selector: #selector(didMove), name: NSWindow.didMoveNotification, object: panel
        )
    }

    func update(state: LightState, sessions: [SessionState]) {
        guard let panel else { return }

        for view in container.arrangedSubviews {
            container.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        invokers.removeAll()

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        let iconView = NSImageView()
        iconView.image = IconRenderer.icon(for: state, side: 16)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        header.addArrangedSubview(iconView)
        header.addArrangedSubview(makeLabel("Claude Code — \(state.label)", bold: true))
        container.addArrangedSubview(header)

        if sessions.isEmpty {
            container.addArrangedSubview(makeLabel("No active sessions", bold: false, secondary: true))
        } else {
            for session in sessions {
                container.addArrangedSubview(makeSessionButton(session))
            }
        }

        container.menu = onRequestMenu?()

        panel.setContentSize(container.fittingSize)
        panel.isMovableByWindowBackground = !Settings.shared.lockToCorner
        reposition()
    }

    private func makeLabel(_ text: String, bold: Bool, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private func makeSessionButton(_ session: SessionState) -> NSButton {
        let button = NSButton(title: "\(session.state.dot) \(session.project)", target: nil, action: nil)
        button.isBordered = false
        button.alignment = .left
        button.contentTintColor = .labelColor
        button.font = .systemFont(ofSize: 12)
        button.toolTip = "\(session.cwd)\n\(session.termProgram) · \(session.tty.isEmpty ? "tty unknown" : session.tty)"
        let invoker = ClosureInvoker { [weak self] in self?.onFocus?(session) }
        button.target = invoker
        button.action = #selector(ClosureInvoker.fire)
        invokers.append(invoker)
        return button
    }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let settings = Settings.shared
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let margin: CGFloat = 16

        let origin: CGPoint
        if !settings.lockToCorner, let saved = settings.floatingOrigin {
            origin = saved
        } else {
            switch settings.corner {
            case .topLeft:     origin = CGPoint(x: visible.minX + margin, y: visible.maxY - size.height - margin)
            case .topRight:    origin = CGPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
            case .bottomLeft:  origin = CGPoint(x: visible.minX + margin, y: visible.minY + margin)
            case .bottomRight: origin = CGPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
            }
        }
        panel.setFrameOrigin(origin)
    }

    @objc private func didMove() {
        guard let panel, !Settings.shared.lockToCorner else { return }
        Settings.shared.floatingOrigin = panel.frame.origin
    }
}
