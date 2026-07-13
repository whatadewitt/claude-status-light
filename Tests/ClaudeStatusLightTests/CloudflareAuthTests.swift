import Foundation
import Testing
@testable import ClaudeStatusLight

/// Scripted HTTPClient: pops responses front-to-back, records requests.
final class MockHTTP: HTTPClient, @unchecked Sendable {
    var responses: [(status: Int, body: String)]
    var requests: [URLRequest] = []
    init(_ responses: [(status: Int, body: String)]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = responses.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

struct CloudflareAuthTests {
    /// Unique service per run so tests never touch the real entry.
    private func freshStore() -> KeychainTokenStore {
        KeychainTokenStore(service: "claude-status-light.test.\(UUID().uuidString)")
    }

    @Test func keychainRoundTripsTokens() throws {
        let store = freshStore()
        defer { store.delete() }
        #expect(store.load() == nil)
        let tokens = OAuthTokens(accessToken: "at", refreshToken: "rt",
                                 expiresAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.save(tokens)
        #expect(store.load() == tokens)
        // Save again overwrites, not duplicates.
        let newer = OAuthTokens(accessToken: "at2", refreshToken: nil,
                                expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save(newer)
        #expect(store.load() == newer)
        store.delete()
        #expect(store.load() == nil)
    }

    @Test func callbackServerResolvesOnTheOAuthRedirect() async throws {
        let server = try await OAuthCallbackServer.start(port: nil, expectedState: "st99")
        defer { server.cancel() }
        let port = server.boundPort
        #expect(port != 0)

        async let code = server.waitForCode(timeout: 10)
        // Simulate the browser redirect (plus a favicon probe that must be ignored).
        let base = "http://127.0.0.1:\(port)"
        _ = try? await URLSession.shared.data(from: URL(string: "\(base)/favicon.ico")!)
        let (body, response) = try await URLSession.shared.data(
            from: URL(string: "\(base)/oauth/callback?code=c0de&state=st99")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: body, encoding: .utf8)?.contains("close this tab") == true)
        #expect(try await code == "c0de")
    }

    @Test func waitForCodeResumesPromptlyWhenCancelled() async throws {
        let server = try await OAuthCallbackServer.start(port: nil, expectedState: "st100")
        defer { server.cancel() }

        let task = Task { try await server.waitForCode(timeout: 60) }
        task.cancel()
        await #expect(throws: Error.self) {
            try await task.value
        }
    }

    @Test func refreshPathUpdatesKeychainWithoutBrowser() async throws {
        let store = freshStore()
        defer { store.delete() }
        try store.save(OAuthTokens(accessToken: "old", refreshToken: "rt",
                                   expiresAt: Date(timeIntervalSinceNow: -60)))
        let http = MockHTTP([(200, #"{"access_token":"fresh","expires_in":3600,"refresh_token":"rt2"}"#)])
        let auth = CloudflareAuth(store: store, http: http)
        auth.openBrowser = { _ in Issue.record("browser must not open on refresh") }

        let token = try await auth.accessToken()
        #expect(token == "fresh")
        #expect(store.load()?.refreshToken == "rt2")
        let sent = String(data: http.requests[0].httpBody ?? Data(), encoding: .utf8) ?? ""
        #expect(sent.contains("grant_type=refresh_token"))
    }

    @Test func cachedTokenSkipsAllIO() async throws {
        let store = freshStore()
        defer { store.delete() }
        try store.save(OAuthTokens(accessToken: "live", refreshToken: nil,
                                   expiresAt: Date(timeIntervalSinceNow: 600)))
        let http = MockHTTP([])
        let auth = CloudflareAuth(store: store, http: http)
        auth.openBrowser = { _ in Issue.record("browser must not open for a cached token") }
        #expect(try await auth.accessToken() == "live")
        #expect(http.requests.isEmpty)
    }
}
