import Foundation

/// Polls the relay Worker for sessions on other machines and in cloud
/// sandboxes. All within-snapshot staleness math uses the snapshot's own
/// `now` (the relay's clock); the local clock only decides whether our
/// cached snapshot itself is too old to trust.
final class RemoteStore {
    /// Host rows drop when their machine hasn't snapshotted for this long.
    static let hostStaleAfter: Double = 60
    /// Cloud rows drop when the relay hasn't heard an event for this long
    /// (mirrors the DO's own TTL — the app filter covers the lazy prune).
    static let cloudStaleAfter: Double = 30 * 60
    /// How often to poll, and how long a cached snapshot stays valid.
    static let pollInterval: TimeInterval = 4
    static let cacheValidFor: TimeInterval = 60

    private let config: RelayConfig?
    private let urlSession: URLSession
    private var timer: Timer?

    // Main-thread state (poll completions hop to main before touching it).
    private var latest: WireSnapshot?
    private var lastSuccess: Date?
    private var lastAttempt: Date?

    var isConfigured: Bool { config != nil }

    /// True once a poll has failed and nothing succeeded within the cache
    /// window — distinguishes "no remote sessions" from "can't see remote".
    var unreachable: Bool {
        guard isConfigured, lastAttempt != nil else { return false }
        guard let lastSuccess else { return true }
        return Date().timeIntervalSince(lastSuccess) > Self.cacheValidFor
    }

    init(config: RelayConfig?, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    func start() {
        guard let config else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll(config: config)
        }
        timer.tolerance = 1
        self.timer = timer
        poll(config: config)
    }

    func sessions() -> [SessionState] {
        guard let latest, let lastSuccess,
              Date().timeIntervalSince(lastSuccess) <= Self.cacheValidFor
        else { return [] }
        return Self.sessions(from: latest)
    }

    /// Pure: wire snapshot → display sessions, staleness on the relay clock.
    static func sessions(from snapshot: WireSnapshot) -> [SessionState] {
        var result: [SessionState] = []
        for host in snapshot.hosts where snapshot.now - host.receivedAt <= hostStaleAfter {
            result.append(contentsOf: host.sessions.compactMap { $0.sessionState(origin: host.name) })
        }
        result.append(contentsOf: snapshot.cloud
            .filter { snapshot.now - $0.receivedAt <= cloudStaleAfter }
            .compactMap { $0.sessionState() })
        return result
    }

    /// Pure: one list for every surface, most recent first (the order
    /// StateStore already uses).
    static func merge(local: [SessionState], remote: [SessionState]) -> [SessionState] {
        (local + remote).sorted { $0.updatedAt > $1.updatedAt }
    }

    private func poll(config: RelayConfig) {
        lastAttempt = Date()
        var request = URLRequest(url: config.url.appendingPathComponent("sessions"))
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.pollInterval

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard
                let data,
                (response as? HTTPURLResponse)?.statusCode == 200,
                let snapshot = try? JSONDecoder().decode(WireSnapshot.self, from: data)
            else { return }  // failure: cache ages out on its own
            DispatchQueue.main.async {
                self?.latest = snapshot
                self?.lastSuccess = Date()
            }
        }.resume()
    }
}
