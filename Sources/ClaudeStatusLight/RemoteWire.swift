import Foundation

/// Wire format shared with the relay Worker (relay/src/relay-do.ts) and the
/// publisher. Times are epoch seconds. Keys are snake_case to match the
/// hook-file format the rest of the pipeline already speaks.
struct WireSession: Codable, Equatable {
    var sessionID: String
    var state: String
    var cwd: String
    var termProgram: String
    var tty: String
    var updatedAt: Double
    var agents: Int
    var title: String?
    var shells: [String]
    var background: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state, cwd
        case termProgram = "term_program"
        case tty
        case updatedAt = "updated_at"
        case agents, title, shells, background
    }
}

// Conversions live in an extension so the struct keeps its synthesized
// memberwise init (an init declared in the main body would suppress it,
// and tests build WireSession values directly).
extension WireSession {
    /// Publisher side: capture the locally derived truth, including the
    /// background verdict — the receiver can't recompute it without a pid.
    init(from session: SessionState) {
        sessionID = session.sessionID
        state = session.state.rawValue
        cwd = session.cwd
        termProgram = session.termProgram
        tty = session.tty
        updatedAt = session.updatedAt.timeIntervalSince1970
        agents = session.agents
        title = session.title
        shells = session.shells
        background = session.isBackground
    }

    /// App side: a remote session never carries a pid (liveness is the
    /// host's heartbeat, not a local process). Unknown states are dropped
    /// rather than guessed.
    func sessionState(origin: String) -> SessionState? {
        guard let light = LightState(rawValue: state) else { return nil }
        return SessionState(
            sessionID: sessionID, state: light, cwd: cwd,
            termProgram: termProgram, tty: tty, pid: nil,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            agents: agents, title: title, shells: shells,
            origin: origin, backgroundOverride: background
        )
    }
}

struct WireHost: Codable {
    var name: String
    var receivedAt: Double
    var sessions: [WireSession]

    enum CodingKeys: String, CodingKey {
        case name
        case receivedAt = "received_at"
        case sessions
    }
}

struct WireCloudSession: Codable {
    var sessionID: String
    var state: String
    var repo: String
    var agents: Int
    var receivedAt: Double

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state, repo, agents
        case receivedAt = "received_at"
    }

    /// Cloud sessions have no terminal and no transcript on this machine:
    /// repo name stands in for cwd (display uses its last path component,
    /// so a bare name flows through), updated = when the relay last heard.
    func sessionState() -> SessionState? {
        guard let light = LightState(rawValue: state) else { return nil }
        return SessionState(
            sessionID: sessionID, state: light, cwd: repo,
            termProgram: "cloud", tty: "", pid: nil,
            updatedAt: Date(timeIntervalSince1970: receivedAt),
            agents: agents, title: nil, shells: [],
            origin: "cloud", backgroundOverride: true
        )
    }
}

struct WireSnapshot: Codable {
    var now: Double
    var hosts: [WireHost]
    var cloud: [WireCloudSession]
}
