import AppKit
import Foundation

/// Brings the terminal window/tab that hosts a given session to the front.
enum TerminalFocuser {
    static func focus(_ s: SessionState) {
        // With a known tty we can target the exact tab; otherwise just raise the app.
        if !s.tty.isEmpty, let script = script(for: s.termProgram, tty: s.tty) {
            runAppleScript(script)
        } else {
            activateApp(for: s.termProgram)
        }
    }

    private static func script(for termProgram: String, tty: String) -> String? {
        let tty = tty.replacingOccurrences(of: "\"", with: "")
        switch termProgram {
        case "Apple_Terminal":
            return """
            tell application "Terminal"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            if (tty of t) is "\(tty)" then
                                set selected of t to true
                                set frontmost of w to true
                                return
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            """
        case "iTerm.app":
            return """
            tell application "iTerm"
                activate
                repeat with w in windows
                    repeat with t in tabs of w
                        repeat with s in sessions of t
                            try
                                if (tty of s) is "\(tty)" then
                                    select w
                                    select t
                                    select s
                                    return
                                end if
                            end try
                        end repeat
                    end repeat
                end repeat
            end tell
            """
        default:
            // Ghostty, WezTerm, VS Code, etc. don't expose per-tab tty via
            // AppleScript — fall back to activating the app.
            return nil
        }
    }

    private static func activateApp(for termProgram: String) {
        let appName: String?
        switch termProgram {
        case "Apple_Terminal": appName = "Terminal"
        case "iTerm.app":      appName = "iTerm"
        case "vscode":         appName = "Visual Studio Code"
        case "WezTerm":        appName = "WezTerm"
        case "Hyper":          appName = "Hyper"
        case "Tabby":          appName = "Tabby"
        case "ghostty":        appName = "Ghostty"
        default:               appName = nil
        }
        guard let appName else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", appName]
        try? proc.run()
    }

    private static func runAppleScript(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
            proc.waitUntilExit()
        }
    }
}
