import CryptoKit
import Foundation

/// Errors from the browser-login leg. Every case renders as a plain sentence
/// in the progress sheet.
enum AuthError: LocalizedError, Equatable {
    case portInUse
    case stateMismatch
    case denied(String)
    case badCallback
    case timeout
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .portInUse: return "Port 8976 is busy — close any running `wrangler login` and try again."
        case .stateMismatch: return "Login callback didn't match this attempt — try again."
        case .denied(let reason): return "Cloudflare login was declined (\(reason))."
        case .badCallback: return "Couldn't read the login callback — try again."
        case .timeout: return "Login timed out — the browser window may have been closed."
        case .httpStatus(let code): return "Cloudflare login failed (HTTP \(code))."
        }
    }
}

/// PKCE pair, matching wrangler: 96-char verifier from the RFC 7636 charset,
/// S256 challenge (base64url, no padding).
struct PKCE {
    static let charset = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    let verifier: String

    init(verifier: String? = nil) {
        self.verifier = verifier ?? String((0..<96).map { _ in Self.charset.randomElement()! })
    }

    var challenge: String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLNoPad
    }
}

extension Data {
    var base64URLNoPad: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The wire shape of dash.cloudflare.com's token endpoint responses.
struct TokenResponse: Decodable {
    let access_token: String
    let expires_in: Double
    let refresh_token: String?
}

/// What we persist in the Keychain: the access token with a precomputed
/// expiry (30 s grace so a token never dies mid-deploy).
struct OAuthTokens: Codable, Equatable {
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date

    init(accessToken: String, refreshToken: String?, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    init(wire: TokenResponse, now: Date) {
        self.init(accessToken: wire.access_token,
                  refreshToken: wire.refresh_token,
                  expiresAt: now.addingTimeInterval(wire.expires_in - 30))
    }
}

enum AuthAction: Equatable {
    case useCached(String)
    case refresh(String)
    case interactive
}

/// Wrangler's OAuth contract, verified against cloudflare/workers-sdk
/// (2026-07-13). Cloudflare has no third-party OAuth registration; reusing
/// wrangler's public client ID is the documented trade-off in the README.
enum CloudflareOAuth {
    static let clientID = "54d11594-84e4-41aa-b438-e81b8fa78ee7"
    static let authURL = URL(string: "https://dash.cloudflare.com/oauth2/auth")!
    static let tokenURL = URL(string: "https://dash.cloudflare.com/oauth2/token")!
    static let callbackURL = URL(string: "http://localhost:8976/oauth/callback")!
    static let callbackPort: UInt16 = 8976
    static let scopes = "account:read user:read workers:write workers_scripts:write offline_access"

    static func authorizationURL(state: String, challenge: String) -> URL {
        var comps = URLComponents(url: authURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: callbackURL.absoluteString),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return comps.url!
    }

    static func exchangeRequest(code: String, verifier: String) -> URLRequest {
        formRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": callbackURL.absoluteString,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    static func refreshRequest(refreshToken: String) -> URLRequest {
        formRequest([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
    }

    static func action(for tokens: OAuthTokens?, now: Date) -> AuthAction {
        guard let tokens else { return .interactive }
        if tokens.expiresAt > now { return .useCached(tokens.accessToken) }
        if let refresh = tokens.refreshToken { return .refresh(refresh) }
        return .interactive
    }

    /// First line of an HTTP request hitting the loopback listener → the auth
    /// code. nil means "not the callback" (favicon and friends): respond 404
    /// and keep listening. Throws on decline / state mismatch / garbage.
    static func parseCallback(_ requestLine: String, expectedState: String) throws -> String? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let comps = URLComponents(string: String(parts[1]))
        else { throw AuthError.badCallback }
        guard comps.path == "/oauth/callback" else { return nil }
        let query = { name in comps.queryItems?.first { $0.name == name }?.value }
        if let error = query("error") { throw AuthError.denied(error) }
        guard query("state") == expectedState else { throw AuthError.stateMismatch }
        guard let code = query("code"), !code.isEmpty else { throw AuthError.badCallback }
        return code
    }

    private static func formRequest(_ fields: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let allowedCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let sorted = fields.sorted { $0.key < $1.key }
        let bodyParts = sorted.map { key, value -> String in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        request.httpBody = Data(bodyParts.joined(separator: "&").utf8)
        return request
    }
}
