import AppKit

// Hidden mode used by the installer to generate the app bundle icon.
let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--render-iconset"), i + 1 < arguments.count {
    IconRenderer.writeIconset(to: arguments[i + 1])
    exit(0)
}

// Headless publisher mode: mirror this machine's sessions to the relay.
// No NSApplication — runs fine from launchd with no UI.
if arguments.contains("--publish") {
    guard let config = RelayConfig.load() else {
        FileHandle.standardError.write(Data(
            "claude-status-light --publish: no \(RelayConfig.defaultPath.path); run scripts/deploy-relay.sh first\n".utf8))
        exit(1)
    }
    Publisher.run(config: config)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
