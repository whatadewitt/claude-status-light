import AppKit

/// Owns the menu bar item. Shows/hides it and keeps its icon + menu current.
final class StatusBarController {
    private var statusItem: NSStatusItem?

    var isVisible: Bool { statusItem != nil }

    func setVisible(_ visible: Bool) {
        if visible, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.imagePosition = .imageOnly
            statusItem = item
        } else if !visible, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    func update(state: LightState, menu: NSMenu) {
        guard let statusItem else { return }
        statusItem.button?.image = IconRenderer.icon(for: state, side: 18)
        statusItem.button?.toolTip = "Claude Code: \(state.label)"
        statusItem.menu = menu
    }
}
