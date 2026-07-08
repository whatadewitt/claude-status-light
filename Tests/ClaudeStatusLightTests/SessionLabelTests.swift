import Foundation
import Testing
@testable import ClaudeStatusLight

/// The row descriptor shared by the menu and the floating panel.
struct SessionLabelTests {
    private func session(
        tty: String = "",
        pid: Int? = 4242,
        agents: Int = 0,
        title: String? = nil
    ) -> SessionState {
        SessionState(
            sessionID: "s", state: .idle, cwd: "/tmp/mlb-props",
            termProgram: "unknown", tty: tty, pid: pid,
            updatedAt: Date(), agents: agents, title: title
        )
    }

    @Test func titledBackgroundSessionShowsProjectAndTitle() {
        let s = session(title: "Improve system win rate from 59%")
        #expect(s.displayName == "mlb-props · Improve system win rate from 59%")
    }

    @Test func untitledBackgroundSessionKeepsBgMarker() {
        #expect(session().displayName == "mlb-props (bg)")
    }

    @Test func interactiveSessionIgnoresTitle() {
        let s = session(tty: "/dev/ttys000", title: "some conversation title")
        #expect(s.displayName == "mlb-props")
    }

    @Test func longTitlesAreTruncated() {
        let s = session(title: String(repeating: "x", count: 80))
        #expect(s.displayName == "mlb-props · " + String(repeating: "x", count: 47) + "…")
    }

    @Test func agentsSuffixPluralizes() {
        #expect(session().agentsSuffix == "")
        #expect(session(agents: 1).agentsSuffix == " · 1 agent")
        #expect(session(agents: 3).agentsSuffix == " · 3 agents")
    }
}
