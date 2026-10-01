import AppKit

/// A small always-on-top desktop panel that mirrors the status and lists
/// active sessions. Can be locked to a screen corner or dragged freely.
///
/// With auto-hide on, it rests as a mascot-only tile and slides out to the
/// full list on hover, or by itself when a session starts waiting for input
/// (staying out until hovered and left, or the wait clears).
final class FloatingPanelController: NSObject {
    private var panel: NSPanel?
    private var effect: HoverEffectView?
    private let container = NSStackView()
    private let iconView = NSImageView()
    private let tileIcon = NSImageView()
    private var invokers: [ClosureInvoker] = []

    private static let tileSide: CGFloat = 44
    private static let tileIconSide: CGFloat = 28
    private static let margin: CGFloat = 16

    // Auto-hide state.
    private var expanded = false
    private var hovering = false
    private var heldOpenForInput = false
    private var previouslyWaiting: Set<String> = []
    private var collapseWork: DispatchWorkItem?
    private var animating = false
    /// Corner the tile stays pinned to while expanded — fixed at collapse
    /// time so dragging the open panel doesn't flip its growth direction.
    private var anchor: ScreenCorner = .topRight

    private var autoHide: Bool { Settings.shared.autoHideFloating }
    private var showingFull: Bool { !autoHide || expanded }

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

        let effect = HoverEffectView()
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
        tileIcon.translatesAutoresizingMaskIntoConstraints = false
        effect.onHover = { [weak self] inside in self?.hoverChanged(inside) }

        panel.contentView = effect
        self.panel = panel
        self.effect = effect
        showContent(full: showingFull)

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

        effect?.menu = onRequestMenu?()
        panel.isMovableByWindowBackground = !Settings.shared.lockToCorner

        let waiting = Set(sessions.filter { $0.state == .attention }.map(\.sessionID))
        if PanelGeometry.shouldPopOut(waiting: waiting, previouslyWaiting: previouslyWaiting) {
            heldOpenForInput = true
        } else if waiting.isEmpty {
            heldOpenForInput = false
        }
        previouslyWaiting = waiting

        if !autoHide {
            expanded = false
            place(animated: false)
        } else {
            setExpanded(hovering || heldOpenForInput)
        }
    }

    /// Swaps just the mascot glyph — called on every dance frame. `render`
    /// draws the current frame at the requested point size.
    func setIcon(_ render: (CGFloat) -> NSImage) {
        iconView.image = render(16)
        if autoHide { tileIcon.image = render(Self.tileIconSide) }
    }

    // MARK: - Auto-hide

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        collapseWork?.cancel()
        guard autoHide else { return }
        if inside {
            setExpanded(true)
        } else {
            heldOpenForInput = false
            // Grace period so brushing past the edge doesn't snap it shut.
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering, !self.heldOpenForInput else { return }
                self.setExpanded(false)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    private func setExpanded(_ want: Bool) {
        guard want != expanded else {
            place(animated: false)
            return
        }
        expanded = want
        place(animated: true)
    }

    /// Puts either the full session list or the lone mascot in the panel.
    private func showContent(full: Bool) {
        guard let effect else { return }
        let view: NSView = full ? container : tileIcon
        guard view.superview !== effect else { return }
        (full ? tileIcon : container).removeFromSuperview()
        effect.addSubview(view)
        if full {
            // Pinned top-leading only: the panel is sized explicitly, and
            // edge-to-edge constraints would fight the slide animation.
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                container.topAnchor.constraint(equalTo: effect.topAnchor),
            ])
        } else {
            NSLayoutConstraint.activate([
                tileIcon.centerXAnchor.constraint(equalTo: effect.centerXAnchor),
                tileIcon.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            ])
        }
    }

    /// Panel width sized for the worst-case title so state flips never change
    /// it, and computed explicitly so both edge insets are honored (the stack
    /// view's fittingSize drops the trailing inset). Only the session list can
    /// widen it further.
    private func stableWidth() -> CGFloat {
        let titleFont = NSFont.boldSystemFont(ofSize: 12)
        let states: [LightState] = [.off, .working, .idle, .attention]
        let maxTitle = states
            .map { ("Claude Code — \($0.label)" as NSString).size(withAttributes: [.font: titleFont]).width }
            .max() ?? 0
        let insets = container.edgeInsets.left + container.edgeInsets.right
        let titleRow = 16 + 6 + ceil(maxTitle) // icon + spacing + text
        let widestRow = container.arrangedSubviews
            .map { $0.fittingSize.width }
            .max() ?? 0
        return max(titleRow, widestRow) + insets
    }

    private func makeLabel(_ text: String, bold: Bool, secondary: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: 12) : .systemFont(ofSize: 12)
        field.textColor = secondary ? .secondaryLabelColor : .labelColor
        return field
    }

    private func makeSessionButton(_ session: SessionState) -> NSButton {
        let button = NSButton(title: "\(session.state.dot) \(session.displayName)\(session.modeSuffix)\(session.shellsSuffix)\(session.agentsSuffix)", target: nil, action: nil)
        button.isBordered = false
        button.alignment = .left
        button.contentTintColor = session.isParked ? .secondaryLabelColor : .labelColor
        button.font = .systemFont(ofSize: 12)
        button.toolTip = session.tooltip
        let invoker = ClosureInvoker { [weak self] in self?.onFocus?(session) }
        button.target = invoker
        button.action = #selector(ClosureInvoker.fire)
        invokers.append(invoker)
        return button
    }

    /// Sizes and positions the panel for the current mode. Without
    /// auto-hide it's the full list at the saved spot or locked corner; with
    /// it, the saved spot / corner belongs to the tile and the full list
    /// grows out of it.
    private func place(animated: Bool) {
        guard let panel, let screen = NSScreen.main, !animating else { return }
        let settings = Settings.shared
        let visible = screen.visibleFrame
        let fullSize = CGSize(width: stableWidth(), height: container.fittingSize.height)

        let target: CGRect
        if !autoHide {
            target = CGRect(origin: origin(for: fullSize, in: visible), size: fullSize)
        } else {
            let tileSize = CGSize(width: Self.tileSide, height: Self.tileSide)
            let tile = CGRect(origin: origin(for: tileSize, in: visible), size: tileSize)
            if !expanded {
                anchor = settings.lockToCorner || settings.floatingOrigin == nil
                    ? settings.corner
                    : PanelGeometry.quadrant(of: tile, in: visible)
            }
            target = expanded
                ? PanelGeometry.frame(size: fullSize, keeping: anchor, of: tile, within: visible)
                : tile
        }

        // Expanding: show the list first so it's revealed as the panel grows.
        // Collapsing: keep it until the panel has shrunk, then swap.
        if showingFull { showContent(full: true) }
        guard animated else {
            if !showingFull { showContent(full: false) }
            if panel.frame != target { panel.setFrame(target, display: true) }
            return
        }
        animating = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.animating = false
            self.place(animated: false)  // settle: swap content, catch updates
        })
    }

    /// Saved custom spot, or the locked/default corner with a 16pt margin.
    private func origin(for size: CGSize, in visible: CGRect) -> CGPoint {
        let settings = Settings.shared
        if !settings.lockToCorner, let saved = settings.floatingOrigin { return saved }
        let m = Self.margin
        switch settings.corner {
        case .topLeft:     return CGPoint(x: visible.minX + m, y: visible.maxY - size.height - m)
        case .topRight:    return CGPoint(x: visible.maxX - size.width - m, y: visible.maxY - size.height - m)
        case .bottomLeft:  return CGPoint(x: visible.minX + m, y: visible.minY + m)
        case .bottomRight: return CGPoint(x: visible.maxX - size.width - m, y: visible.minY + m)
        }
    }

    @objc private func didMove() {
        guard let panel, !Settings.shared.lockToCorner, !animating else { return }
        guard autoHide, expanded else {
            Settings.shared.floatingOrigin = panel.frame.origin
            return
        }
        // Dragging the open panel: the tile sits in its anchored corner.
        let f = panel.frame, t = Self.tileSide
        let x = (anchor == .topLeft || anchor == .bottomLeft) ? f.minX : f.maxX - t
        let y = (anchor == .bottomLeft || anchor == .bottomRight) ? f.minY : f.maxY - t
        Settings.shared.floatingOrigin = CGPoint(x: x, y: y)
    }
}

/// The panel's blurred background, reporting the pointer entering and
/// leaving. `.activeAlways` matters: the panel never makes the app active.
private final class HoverEffectView: NSVisualEffectView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}
