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

    /// Short hostname the same way deploy-relay.sh computes it
    /// (gethostname up to the first dot).
    static func shortHostname() -> String {
        String(ProcessInfo.processInfo.hostName.split(separator: ".").first ?? "mac")
    }

    /// Writes the config the way scripts/deploy-relay.sh does: pretty JSON,
    /// owner-only permissions.
    func write(to file: URL = RelayConfig.defaultPath) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["url": url.absoluteString, "token": token, "host": host],
            options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
