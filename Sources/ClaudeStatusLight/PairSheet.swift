import AppKit

/// Modal sheet for "Pair another machine…": shows the single-use command
/// once the relay hands back a code, or the failure if it didn't. Same
/// shape as DeployProgressSheet: @MainActor, ClosureInvoker targets,
/// retained by the controller until dismissed.
@MainActor
final class PairSheet {
    let window: NSWindow
    private let status = NSTextField(wrappingLabelWithString: "Requesting pairing code…")
    private let command = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(labelWithString: "Expires in 10 minutes, works once.")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let close = NSButton(title: "Cancel", target: nil, action: nil)
    private var invokers: [ClosureInvoker] = []
    /// Invoked when the user dismisses the sheet — the caller cancels a
    /// still-in-flight request task.
    var onCancel: (() -> Void)?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Pair another machine"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        status.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(status)

        command.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        command.preferredMaxLayoutWidth = 360
        command.isSelectable = true
        command.isHidden = true
        stack.addArrangedSubview(command)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.isHidden = true
        stack.addArrangedSubview(note)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        copyButton.bezelStyle = .rounded
        copyButton.isHidden = true
        let copyInvoker = ClosureInvoker { [weak self] in self?.copyCommand() }
        copyButton.target = copyInvoker
        copyButton.action = #selector(ClosureInvoker.fire)
        invokers.append(copyInvoker)
        buttons.addArrangedSubview(copyButton)

        close.bezelStyle = .rounded
        let closeInvoker = ClosureInvoker { [weak self] in self?.dismiss() }
        close.target = closeInvoker
        close.action = #selector(ClosureInvoker.fire)
        invokers.append(closeInvoker)
        buttons.addArrangedSubview(close)
        stack.addArrangedSubview(buttons)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        window.contentView = content
        resize()
    }

    func show(command commandText: String) {
        status.stringValue = "Run this on the other Mac (with this repo cloned):"
        command.stringValue = commandText
        command.isHidden = false
        note.isHidden = false
        copyButton.isHidden = false
        close.title = "Close"
        resize()
    }

    func fail(_ message: String) {
        status.stringValue = "✗ " + message
        close.title = "Close"
        resize()
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command.stringValue, forType: .string)
    }

    private func dismiss() {
        onCancel?()
        window.sheetParent?.endSheet(window)
    }

    private func resize() {
        window.setContentSize(window.contentView!.fittingSize)
    }
}
