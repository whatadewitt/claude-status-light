import Foundation

/// Pure pieces of "Pair another machine…": the /pair request, its response,
/// and the command string pasted on the other Mac. The AppKit glue that
/// shows the result lives in PairSheet.swift.
enum Pairing {
    /// What POST /pair returns: the single-use code plus its expiry stamp.
    struct Response: Decodable, Equatable {
        let code: String
        let expiresAt: Int

        enum CodingKeys: String, CodingKey {
            case code
            case expiresAt = "expires_at"
        }
    }

    /// POST /pair carrying the relay config the other machine will receive.
    /// `host` is deliberately absent — the receiver writes its own.
    static func request(config: RelayConfig) -> URLRequest? {
        guard let url = URL(string: "pair", relativeTo: config.url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["url": config.url.absoluteString, "token": config.token],
            options: [.sortedKeys])
        return request
    }

    static func decode(_ data: Data) -> Response? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.code.isEmpty else { return nil }
        return response
    }

    /// The exact line the user pastes on the other Mac (from a clone of this
    /// repo) — must match install-publisher.sh's --pair flag.
    static func command(url: URL, code: String) -> String {
        "scripts/install-publisher.sh --pair \(url.absoluteString) \(code)"
    }
}
