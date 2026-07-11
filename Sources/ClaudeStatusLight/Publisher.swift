import Foundation

/// Headless `--publish` mode: runs on a remote Mac (launchd agent) and
/// mirrors that machine's locally derived sessions — PID-checked, shells
/// scanned, titles read — up to the relay. Pushes on change, and at least
/// every 15s: the snapshot is also the host's heartbeat, so the app can
/// drop this host's rows when the pushes stop.
enum Publisher {
    static let heartbeat: TimeInterval = 15
    static let tick: TimeInterval = 2

    /// {"sessions":[…]} — sorted sessions + sorted keys so identical state
    /// yields identical bytes (change detection is a Data compare).
    static func encodeSnapshot(_ sessions: [SessionState]) -> Data? {
        let wire = sessions.map(WireSession.init(from:)).sorted { $0.sessionID < $1.sessionID }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(["sessions": wire])
    }

    static func shouldPush(payload: Data, lastPayload: Data?, lastPush: Date, now: Date) -> Bool {
        payload != lastPayload || now.timeIntervalSince(lastPush) >= heartbeat
    }

    static func run(config: RelayConfig) -> Never {
        let store = StateStore()
        var lastPayload: Data?
        var lastPush = Date.distantPast

        while true {
            let now = Date()
            if let payload = encodeSnapshot(store.activeSessions()),
               shouldPush(payload: payload, lastPayload: lastPayload, lastPush: lastPush, now: now),
               push(payload, config: config) {
                lastPayload = payload
                lastPush = now
            }
            // Failures fall through quietly: the next tick retries, and the
            // app drops this host's rows if silence exceeds its window.
            Thread.sleep(forTimeInterval: tick)
        }
    }

    private static func push(_ body: Data, config: RelayConfig) -> Bool {
        let encodedHost = config.host.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.host
        guard let url = URL(string: "hosts/\(encodedHost)", relativeTo: config.url) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var ok = false
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return ok
    }
}
