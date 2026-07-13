import Foundation
import Security

struct CFAccount: Decodable, Equatable {
    let id: String
    let name: String
}

struct CFAPIError: Decodable, Error, LocalizedError {
    let code: Int
    let message: String
    var errorDescription: String? { "Cloudflare: \(message) (code \(code))" }
}

/// Every REST response arrives in this envelope; `success:false` carries the
/// human-readable error we surface verbatim in the progress sheet.
struct CFEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let errors: [CFAPIError]
    let result: T?
}

struct SubdomainResult: Decodable {
    let subdomain: String
}

/// Request builders for the five deploy steps — pure, verified against
/// developers.cloudflare.com (2026-07-13). All auth is the OAuth access
/// token as a plain Bearer header, exactly as wrangler sends it.
enum CloudflareAPI {
    static let base = URL(string: "https://api.cloudflare.com/client/v4")!
    static let scriptName = "claude-status-relay"
    /// Must match relay/wrangler.jsonc.
    static let compatibilityDate = "2026-07-10"
    static let compatibilityFlags = ["nodejs_compat"]

    static func accountsRequest(token: String) -> URLRequest {
        request("GET", "accounts", token: token)
    }

    static func scriptExistsRequest(account: String, token: String) -> URLRequest {
        request("GET", "accounts/\(account)/workers/scripts/\(scriptName)", token: token)
    }

    static func uploadRequest(account: String, includeMigration: Bool, moduleJS: String,
                              boundary: String = UUID().uuidString, token: String) -> URLRequest {
        var meta: [String: Any] = [
            "main_module": "index.js",
            "compatibility_date": compatibilityDate,
            "compatibility_flags": compatibilityFlags,
            "bindings": [[
                "type": "durable_object_namespace",
                "name": "RELAY",
                "class_name": "RelayDO",
            ]],
        ]
        if includeMigration {
            meta["migrations"] = ["new_tag": "v1", "steps": [["new_sqlite_classes": ["RelayDO"]]]]
        }
        let metaJSON = String(
            data: try! JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys]),
            encoding: .utf8)!

        var body = ""
        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"metadata\"\r\n"
        body += "Content-Type: application/json\r\n\r\n"
        body += metaJSON + "\r\n"
        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"index.js\"; filename=\"index.js\"\r\n"
        body += "Content-Type: application/javascript+module\r\n\r\n"
        body += moduleJS + "\r\n"
        body += "--\(boundary)--\r\n"

        var req = request("PUT", "accounts/\(account)/workers/scripts/\(scriptName)", token: token)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(body.utf8)
        return req
    }

    static func enableSubdomainRequest(account: String, token: String) -> URLRequest {
        var req = request("POST", "accounts/\(account)/workers/scripts/\(scriptName)/subdomain", token: token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"enabled":true}"#.utf8)
        return req
    }

    static func accountSubdomainRequest(account: String, token: String) -> URLRequest {
        request("GET", "accounts/\(account)/workers/subdomain", token: token)
    }

    static func secretRequest(account: String, relayToken: String, token: String) -> URLRequest {
        var req = request("PUT", "accounts/\(account)/workers/scripts/\(scriptName)/secrets", token: token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try! JSONSerialization.data(
            withJSONObject: ["name": "RELAY_TOKEN", "text": relayToken, "type": "secret_text"],
            options: [.sortedKeys])
        return req
    }

    static func workerURL(subdomain: String) -> URL {
        URL(string: "https://\(scriptName).\(subdomain).workers.dev")!
    }

    /// Same idempotency contract as scripts/deploy-relay.sh: keep an existing
    /// relay token so already-configured remote machines stay valid.
    static func newRelayToken(existing: RelayConfig?) -> String {
        if let token = existing?.token, !token.isEmpty { return token }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func request(_ method: String, _ path: String, token: String) -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }
}
