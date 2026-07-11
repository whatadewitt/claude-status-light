import Foundation

/// Connection details for the relay Worker, written by scripts/deploy-relay.sh
/// to ~/.claude/status-light/relay.json (chmod 600). Absent file = the whole
/// remote-sessions feature is off.
struct RelayConfig: Equatable {
    let url: URL
    let token: String
    let host: String

    static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/status-light/relay.json")

    static func load(from file: URL = defaultPath) -> RelayConfig? {
        guard
            let data = try? Data(contentsOf: file),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let urlString = obj["url"] as? String,
            let url = URL(string: urlString),
            let token = obj["token"] as? String, !token.isEmpty
        else { return nil }
        let host = (obj["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.hostName
        return RelayConfig(url: url, token: token, host: host)
    }
}
