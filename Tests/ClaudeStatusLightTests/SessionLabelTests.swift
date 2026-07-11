import Foundation
import Testing
@testable import ClaudeStatusLight

/// The row descriptor shared by the menu and the floating panel.
struct SessionLabelTests {
    private func session(
        state: LightState = .idle,
        tty: String = "",
        pid: Int? = 4242,
        age: TimeInterval = 0,
        agents: Int = 0,
        title: String? = nil,
        shells: [String] = []
    ) -> SessionState {
        SessionState(
            sessionID: "s", state: state, cwd: "/tmp/mlb-props",
            termProgram: "unknown", tty: tty, pid: pid,
            updatedAt: Date().addingTimeInterval(-age),
            agents: agents, title: title, shells: shells
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

    @Test func shellsSuffixShowsTheCommand() {
        #expect(session().shellsSuffix == "")
        #expect(session(shells: ["uv run python train.py"]).shellsSuffix
                == " · sh: uv run python train.py")
    }

    @Test func shellsSuffixTruncatesAndCounts() {
        let long = String(repeating: "x", count: 60)
        #expect(session(shells: [long]).shellsSuffix
                == " · sh: " + String(repeating: "x", count: 39) + "…")
        #expect(session(shells: ["first command", "second"]).shellsSuffix
                == " · 2 sh: first command")
    }

    @Test func titledAgentRowSuppressesShellDetail() {
        // A titled background agent already says what it's doing; its shells
        // stay in the tooltip (and keep the row yellow) but out of the label.
        let agent = session(title: "Improve win rate", shells: ["uv run python sweep.py"])
        #expect(agent.shellsSuffix == "")
        #expect(agent.tooltip.contains("sh: uv run python sweep.py"))
        // An interactive session with a running shell keeps the inline detail
        // even if its transcript happens to have a title.
        let interactive = session(tty: "/dev/ttys000", title: "chat title", shells: ["sleep 5"])
        #expect(interactive.shellsSuffix == " · sh: sleep 5")
    }

    @Test func tooltipListsFullShellCommands() {
        let s = session(tty: "/dev/ttys000", shells: ["uv run python train.py --all"])
        #expect(s.tooltip == "/tmp/mlb-props\nunknown · /dev/ttys000\nsh: uv run python train.py --all")
    }

    @Test func tooltipMarksBackgroundSessions() {
        #expect(session().tooltip == "/tmp/mlb-props\nunknown · tty unknown\nbackground session (no terminal)")
    }

    // MARK: - Parked agents (idle, headless, quiet)

    @Test func quietIdleBackgroundSessionIsParked() {
        #expect(session(age: 3 * 60).isParked == true)
        #expect(session(age: 3 * 60).tooltip.contains("parked — idle 3m, process alive"))
    }

    @Test func freshOrBusyOrInteractiveSessionsAreNotParked() {
        #expect(session(age: 30).isParked == false)                               // fresh
        #expect(session(state: .working, age: 3 * 60).isParked == false)          // busy
        #expect(session(tty: "/dev/ttys000", age: 60 * 60).isParked == false)     // interactive
    }

    // MARK: - Remote sessions

    private func remoteSession(
        origin: String? = "office-mini",
        state: LightState = .working,
        cwd: String = "/Users/luke/mlb-props",
        title: String? = nil,
        background: Bool? = true,
        age: TimeInterval = 0
    ) -> SessionState {
        SessionState(
            sessionID: "r1", state: state, cwd: cwd, termProgram: "remote",
            tty: "", pid: nil, updatedAt: Date().addingTimeInterval(-age),
            agents: 0, title: title, shells: [],
            origin: origin, backgroundOverride: background
        )
    }

    @Test func originPrefixesDisplayName() {
        #expect(remoteSession(title: "Improve win rate").displayName
            == "office-mini · mlb-props · Improve win rate")
        #expect(remoteSession(origin: "cloud", cwd: "my-repo", background: true).displayName
            == "cloud · my-repo (bg)")
    }

    @Test func localSessionsAreUnchanged() {
        let local = SessionState(
            sessionID: "l1", state: .idle, cwd: "/tmp/proj", termProgram: "iTerm.app",
            tty: "/dev/ttys001", pid: 1, updatedAt: Date(), agents: 0, title: nil, shells: []
        )
        #expect(local.origin == nil)
        #expect(local.displayName == "proj")
        #expect(local.isBackground == false)
    }

    @Test func backgroundOverrideBeatsPidHeuristic() {
        // Remote sessions have no meaningful pid; the publisher's verdict wins.
        #expect(remoteSession(background: true).isBackground == true)
        #expect(remoteSession(background: false).isBackground == false)
    }

    @Test func remoteBackgroundSessionsCanPark() {
        #expect(remoteSession(state: .idle, background: true, age: 3 * 60).isParked == true)
        #expect(remoteSession(state: .idle, background: false, age: 3 * 60).isParked == false)
    }

    @Test func tooltipNamesTheOrigin() {
        #expect(remoteSession().tooltip.contains("remote session on office-mini"))
    }
}
