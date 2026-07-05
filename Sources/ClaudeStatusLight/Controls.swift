import AppKit

/// Wraps a closure as a target/action object. Retain it yourself (menu items
/// keep theirs via `representedObject`; controllers keep theirs in arrays)
/// because AppKit `target` references are weak.
final class ClosureInvoker: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

/// A checkbox bound to a Bool setter.
final class Toggle: NSObject {
    let button: NSButton
    private let onChange: (Bool) -> Void

    init(title: String, value: Bool, onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        self.button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        super.init()
        button.state = value ? .on : .off
        button.target = self
        button.action = #selector(fire)
    }

    @objc private func fire() { onChange(button.state == .on) }
}

/// A popup button bound to an index setter.
final class Picker: NSObject {
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let onChange: (Int) -> Void

    init(titles: [String], selected: Int, onChange: @escaping (Int) -> Void) {
        self.onChange = onChange
        super.init()
        popup.addItems(withTitles: titles)
        popup.selectItem(at: selected)
        popup.target = self
        popup.action = #selector(fire)
    }

    @objc private func fire() { onChange(popup.indexOfSelectedItem) }
}
