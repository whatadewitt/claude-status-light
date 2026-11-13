import Foundation
import UserNotifications

/// Posts the idle / permission nudge.
///
/// Prefers a native notification: it's attributed to this app (not Script
/// Editor), names the project, and is clickable — the tap handler in
/// AppDelegate focuses that session's terminal. If the user hasn't granted
/// notification permission, it falls back to an osascript banner so a nudge
/// still appears (that one isn't clickable).
enum Notifier {
    /// UNUserNotificationCenter needs a real app bundle; calling it from a bare
    /// executable (`swift run`, a checkout build) raises an Objective-C
    /// exception. The installer always produces a bundle, so this only gates
    /// development runs — those get the osascript fallback.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static func requestAuthorization() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func nudge(session: SessionState, minutes: Double) {
        let mins = minutes == floor(minutes)
            ? String(Int(minutes))
            : String(format: "%.1f", minutes)
        let title = "Claude Code — \(session.project)"
        let body = session.state == .attention
            ? "Waiting \(mins) min on a permission prompt. Click to open its terminal."
            : "Idle \(mins) min — reply to keep the context cache warm. Click to open its terminal."

        guard isAvailable else {
            postFallback(title: title, body: body)
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                postNative(center, session: session, title: title, body: body)
            default:
                postFallback(title: title, body: body)
            }
        }
    }

    private static func postNative(_ center: UNUserNotificationCenter,
                                   session: SessionState, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // Enough to focus the right terminal on click, even if the session has
        // since changed state (the tty stays valid while the window is open).
        content.userInfo = [
            "termProgram": session.termProgram,
            "tty": session.tty,
        ]
        let request = UNNotificationRequest(
            identifier: "nudge-\(session.sessionID)", content: content, trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    private static func postFallback(title: String, body: String) {
        let script = """
        display notification "\(esc(body))" with title "\(esc(title))" sound name "Ping"
        """
        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", script]
            try? proc.run()
            proc.waitUntilExit()
        }
    }

    /// Escape a Swift string for embedding in an AppleScript double-quoted literal.
    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
