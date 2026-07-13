import Foundation

enum DeployStep: CaseIterable {
    case account, upload, url, secret, config

    var label: String {
        switch self {
        case .account: return "Finding account"
        case .upload: return "Deploying worker"
        case .url: return "Enabling URL"
        case .secret: return "Setting secret"
        case .config: return "Writing config"
        }
    }
}

enum DeployError: LocalizedError {
    case badStatus(Int)
    case noAccounts
    case cancelled

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "Cloudflare returned HTTP \(code)."
        case .noAccounts: return "Your Cloudflare login has no accounts."
        case .cancelled: return "Deploy cancelled."
        }
    }
}

/// The five REST steps of the spec, in order, reporting each step as it
/// starts. UI supplies the account picker (only consulted for >1 account).
struct CloudflareDeployer {
    let http: HTTPClient
    let pickAccount: ([CFAccount]) async throws -> CFAccount

    init(http: HTTPClient = URLSession.shared,
         pickAccount: @escaping ([CFAccount]) async throws -> CFAccount) {
        self.http = http
        self.pickAccount = pickAccount
    }

    func deploy(accessToken token: String, existing: RelayConfig?,
                configPath: URL = RelayConfig.defaultPath,
                progress: @escaping (DeployStep) -> Void) async throws -> RelayConfig {
        progress(.account)
        let accounts: [CFAccount] = try await fetch(CloudflareAPI.accountsRequest(token: token))
        guard let first = accounts.first else { throw DeployError.noAccounts }
        let account = accounts.count == 1 ? first : try await pickAccount(accounts)

        progress(.upload)
        // Existence probe decides whether the upload carries the first-run
        // DO migration (sending it again with a mismatched tag is rejected).
        let (_, probe) = try await http.data(
            for: CloudflareAPI.scriptExistsRequest(account: account.id, token: token))
        let exists = probe.statusCode == 200
        let _: ScriptResult = try await fetch(CloudflareAPI.uploadRequest(
            account: account.id, includeMigration: !exists,
            moduleJS: RelayWorkerDist.moduleJS, token: token))

        progress(.url)
        let _: SubdomainEnabled = try await fetch(
            CloudflareAPI.enableSubdomainRequest(account: account.id, token: token))
        let sub: SubdomainResult = try await fetch(
            CloudflareAPI.accountSubdomainRequest(account: account.id, token: token))

        progress(.secret)
        let relayToken = CloudflareAPI.newRelayToken(existing: existing)
        let _: SecretResult = try await fetch(
            CloudflareAPI.secretRequest(account: account.id, relayToken: relayToken, token: token))

        progress(.config)
        let config = RelayConfig(url: CloudflareAPI.workerURL(subdomain: sub.subdomain),
                                 token: relayToken,
                                 host: existing?.host ?? RelayConfig.shortHostname())
        try config.write(to: configPath)
        return config
    }

    /// Decode the CF envelope; surface Cloudflare's own error message when
    /// success is false, the bare status when the body isn't an envelope.
    private func fetch<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await http.data(for: request)
        guard let envelope = try? JSONDecoder().decode(CFEnvelope<T>.self, from: data) else {
            throw DeployError.badStatus(response.statusCode)
        }
        guard envelope.success, let result = envelope.result else {
            throw envelope.errors.first ?? DeployError.badStatus(response.statusCode)
        }
        return result
    }
}

private struct ScriptResult: Decodable { let id: String? }
private struct SubdomainEnabled: Decodable { let enabled: Bool }
private struct SecretResult: Decodable { let name: String? }
