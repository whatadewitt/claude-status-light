import AppKit
import Foundation
import Network
import Security

/// Minimal lock-guarded box for a value read/written from a callback that
/// Swift 6 can't prove runs isolated from its capturing context (e.g. an
/// NWListener state handler). Small and `Sendable` on purpose, rather than
/// silencing the checker with `@unchecked Sendable` on the callers' types.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }

    /// Sets to `newValue` and returns what was there before.
    func exchange(_ newValue: Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}

/// Injection seam so deploy/auth logic is testable without the network.
protocol HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

extension URLSession: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse) = try await data(for: request, delegate: nil)
        return (data, response as! HTTPURLResponse)
    }
}

/// OAuth tokens in the login Keychain, one generic-password item.
struct KeychainTokenStore {
    let service: String

    init(service: String = "claude-status-light.cloudflare") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "oauth"]
    }

    func save(_ tokens: OAuthTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        delete()
        var attrs = query
        attrs[kSecValueData as String] = data
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    func load() -> OAuthTokens? {
        var attrs = query
        attrs[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(attrs as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Loopback HTTP listener for the OAuth redirect. Started with the expected
/// state so a redirect is validated the moment it arrives (even before
/// waitForCode is awaited); ignores paths that aren't the callback (browsers
/// probe /favicon.ico); the first valid callback or error is buffered until
/// waitForCode collects it.
final class OAuthCallbackServer {
    private let listener: NWListener
    private let expectedState: String
    private let lock = NSLock()
    private var outcome: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?

    private init(listener: NWListener, expectedState: String) {
        self.listener = listener
        self.expectedState = expectedState
    }

    /// Valid once start() has returned — the listener is ready by then.
    var boundPort: UInt16 { listener.port?.rawValue ?? 0 }

    /// port nil = ephemeral (tests); the real flow uses CloudflareOAuth.callbackPort.
    static func start(port: UInt16?, expectedState: String) async throws -> OAuthCallbackServer {
        let listener: NWListener
        do {
            if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
                listener = try NWListener(using: .tcp, on: nwPort)
            } else {
                listener = try NWListener(using: .tcp)
            }
        } catch {
            throw AuthError.portInUse
        }
        let server = OAuthCallbackServer(listener: listener, expectedState: expectedState)
        listener.newConnectionHandler = { [weak server] connection in
            server?.handle(connection)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // NSLock-guarded flag, not a bare captured var: stateUpdateHandler
            // runs on the listener's queue, which Swift 6 can't prove is
            // isolated from the continuation's caller, so a plain `var`
            // capture is flagged as a concurrency error.
            let resumed = Locked(false)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.exchange(true) == false { cont.resume() }
                case .failed:
                    if resumed.exchange(true) == false { cont.resume(throwing: AuthError.portInUse) }
                default:
                    break
                }
            }
            listener.start(queue: .main)
        }
        return server
    }

    func cancel() { listener.cancel() }

    func waitForCode(timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { cont in
                    self.lock.lock()
                    if let outcome = self.outcome {
                        self.lock.unlock()
                        cont.resume(with: outcome)
                    } else {
                        self.waiter = cont
                        self.lock.unlock()
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // Resume the waiting continuation too — a bare throw here
                // would leak it when the group is cancelled.
                self.deliver(.failure(AuthError.timeout))
                throw AuthError.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AuthError.timeout }
            return first
        }
    }

    /// First outcome wins; resumes an active waiter or buffers for a later one.
    private func deliver(_ result: Result<String, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let text = String(data: data, encoding: .utf8),
                  let firstLine = text.split(separator: "\r\n").first
            else { connection.cancel(); return }
            do {
                if let code = try CloudflareOAuth.parseCallback(String(firstLine), expectedState: self.expectedState) {
                    Self.respond(connection, status: "200 OK",
                                 html: "<html><body><h3>Logged in — you can close this tab.</h3></body></html>")
                    self.deliver(.success(code))
                } else {
                    Self.respond(connection, status: "404 Not Found", html: "")
                }
            } catch {
                Self.respond(connection, status: "400 Bad Request",
                             html: "<html><body>Login failed — return to the app.</body></html>")
                self.deliver(.failure(error))
            }
        }
    }

    private static func respond(_ connection: NWConnection, status: String, html: String) {
        let payload = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        connection.send(content: Data(payload.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Cached → refreshed → interactive browser login, in that order.
final class CloudflareAuth {
    private let store: KeychainTokenStore
    private let http: HTTPClient
    var openBrowser: (URL) -> Void = { NSWorkspace.shared.open($0) }

    init(store: KeychainTokenStore = KeychainTokenStore(), http: HTTPClient = URLSession.shared) {
        self.store = store
        self.http = http
    }

    func accessToken() async throws -> String {
        switch CloudflareOAuth.action(for: store.load(), now: Date()) {
        case .useCached(let token):
            return token
        case .refresh(let refreshToken):
            do { return try await exchange(CloudflareOAuth.refreshRequest(refreshToken: refreshToken)) }
            catch { return try await interactive() }  // stale refresh token → full login
        case .interactive:
            return try await interactive()
        }
    }

    private func interactive() async throws -> String {
        let pkce = PKCE()
        let state = UUID().uuidString
        let server = try await OAuthCallbackServer.start(
            port: CloudflareOAuth.callbackPort, expectedState: state)
        defer { server.cancel() }
        openBrowser(CloudflareOAuth.authorizationURL(state: state, challenge: pkce.challenge))
        let code = try await server.waitForCode(timeout: 300)
        return try await exchange(CloudflareOAuth.exchangeRequest(code: code, verifier: pkce.verifier))
    }

    private func exchange(_ request: URLRequest) async throws -> String {
        let (data, response) = try await http.data(for: request)
        guard response.statusCode == 200 else { throw AuthError.httpStatus(response.statusCode) }
        let tokens = OAuthTokens(wire: try JSONDecoder().decode(TokenResponse.self, from: data), now: Date())
        try? store.save(tokens)
        return tokens.accessToken
    }
}
