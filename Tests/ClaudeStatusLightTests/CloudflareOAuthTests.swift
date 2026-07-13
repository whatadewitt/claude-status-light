import Foundation
import Testing
@testable import ClaudeStatusLight

struct CloudflareOAuthTests {
    @Test func pkceVerifierHas96CharsFromTheWranglerCharset() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let pkce = PKCE(verifier: nil)
        #expect(pkce.verifier.count == 96)
        #expect(pkce.verifier.allSatisfy { allowed.contains($0) })
        #expect(PKCE(verifier: nil).verifier != pkce.verifier)
    }

    @Test func pkceChallengeIsBase64URLSHA256NoPadding() {
        // sha256("test") = 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08
        // base64url of those bytes, no padding:
        #expect(PKCE(verifier: "test").challenge == "n4bQgYhMfWWaL-qgxVrQFaO_TxsrC4Is0V1sFbDwCgg")
    }

    @Test func authorizationURLCarriesTheWranglerContract() throws {
        let url = CloudflareOAuth.authorizationURL(state: "st8", challenge: "ch4l")
        let comps = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(comps.scheme == "https" && comps.host == "dash.cloudflare.com" && comps.path == "/oauth2/auth")
        let q = { name in comps.queryItems?.first { $0.name == name }?.value }
        #expect(q("response_type") == "code")
        #expect(q("client_id") == "54d11594-84e4-41aa-b438-e81b8fa78ee7")
        #expect(q("redirect_uri") == "http://localhost:8976/oauth/callback")
        #expect(q("scope") == "account:read user:read workers:write workers_scripts:write offline_access")
        #expect(q("state") == "st8")
        #expect(q("code_challenge") == "ch4l")
        #expect(q("code_challenge_method") == "S256")
    }

    @Test func exchangeAndRefreshRequestsAreFormEncoded() throws {
        let ex = CloudflareOAuth.exchangeRequest(code: "c0de", verifier: "v3rif")
        #expect(ex.url?.absoluteString == "https://dash.cloudflare.com/oauth2/token")
        #expect(ex.httpMethod == "POST")
        #expect(ex.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        let exBody = String(data: try #require(ex.httpBody), encoding: .utf8)!
        #expect(exBody.contains("grant_type=authorization_code"))
        #expect(exBody.contains("code=c0de"))
        #expect(exBody.contains("code_verifier=v3rif"))
        #expect(exBody.contains("client_id=54d11594-84e4-41aa-b438-e81b8fa78ee7"))
        #expect(exBody.contains("redirect_uri=http%3A%2F%2Flocalhost%3A8976%2Foauth%2Fcallback"))

        let re = CloudflareOAuth.refreshRequest(refreshToken: "r3fresh")
        let reBody = String(data: try #require(re.httpBody), encoding: .utf8)!
        #expect(reBody.contains("grant_type=refresh_token"))
        #expect(reBody.contains("refresh_token=r3fresh"))
    }

    @Test func tokensComputeExpiryWithGrace() throws {
        let wire = try JSONDecoder().decode(TokenResponse.self, from: Data(
            #"{"access_token":"at","expires_in":3600,"refresh_token":"rt","scope":"x"}"#.utf8))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let tokens = OAuthTokens(wire: wire, now: now)
        #expect(tokens.accessToken == "at" && tokens.refreshToken == "rt")
        #expect(tokens.expiresAt == now.addingTimeInterval(3600 - 30))
    }

    @Test func actionPrefersCachedThenRefreshThenInteractive() {
        let now = Date()
        let live = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(60))
        let dead = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: now.addingTimeInterval(-1))
        let deadNoRefresh = OAuthTokens(accessToken: "a", refreshToken: nil, expiresAt: now.addingTimeInterval(-1))
        #expect(CloudflareOAuth.action(for: live, now: now) == .useCached("a"))
        #expect(CloudflareOAuth.action(for: dead, now: now) == .refresh("r"))
        #expect(CloudflareOAuth.action(for: deadNoRefresh, now: now) == .interactive)
        #expect(CloudflareOAuth.action(for: nil, now: now) == .interactive)
    }

    @Test func parseCallbackExtractsCodeAndChecksState() throws {
        let ok = "GET /oauth/callback?code=abc&state=s1 HTTP/1.1"
        #expect(try CloudflareOAuth.parseCallback(ok, expectedState: "s1") == "abc")
        // Non-callback paths (favicon etc.) are nil — the server keeps listening.
        #expect(try CloudflareOAuth.parseCallback("GET /favicon.ico HTTP/1.1", expectedState: "s1") == nil)
        #expect(throws: AuthError.self) {
            try CloudflareOAuth.parseCallback("GET /oauth/callback?code=abc&state=WRONG HTTP/1.1", expectedState: "s1")
        }
        #expect(throws: AuthError.self) {
            try CloudflareOAuth.parseCallback("GET /oauth/callback?error=access_denied&state=s1 HTTP/1.1", expectedState: "s1")
        }
    }
}
