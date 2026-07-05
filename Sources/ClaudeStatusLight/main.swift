import AppKit

// Hidden mode used by the installer to generate the app bundle icon.
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--render-iconset"), i + 1 < arguments.count {
    IconRenderer.writeIconset(to: arguments[i + 1])
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
