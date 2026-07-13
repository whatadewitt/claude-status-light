# In-app Cloudflare relay setup — design

2026-07-13. Approved in conversation (Luke): approach B (pure-Swift REST deploy,
no node at runtime or install) with wrangler-style browser OAuth.

## Goal

A "Remote sessions" section in Settings that deploys the status relay Worker to
the user's own Cloudflare account with one button and a browser login — no
node, npm, or wrangler on the machine. Replaces nothing: `scripts/deploy-relay.sh`
remains the CLI path and the fallback.

## UX

- New Settings section **Remote sessions** (below "Icon"):
  - Status line: `not set up` when `~/.claude/status-light/relay.json` is
    absent; otherwise the relay URL from it.
  - One adaptive button: **Set up Cloudflare relay…** / **Re-deploy relay…**.
- Clicking opens a small progress sheet that streams steps:
  `Logging in… → Deploying worker… → Enabling URL… → Setting secret… →
  Writing config… → Done`. Each step flips to ✓ or shows its error inline.
- Browser opens only when there is no valid Keychain token. Multiple Cloudflare
  accounts → the sheet shows an account picker; a single account is used
  silently.
- On success the app begins polling immediately (`RemoteStore` restarted with
  the fresh config); no app restart.

## Auth — wrangler's OAuth flow in Swift

- Authorization-code + PKCE (S256) against Cloudflare's dash OAuth endpoints,
  using wrangler's public client ID and its standard localhost callback
  (loopback HTTP listener via Network.framework, one-shot, times out after
  ~5 min). Scopes trimmed to what deploy needs: account read, user read,
  workers scripts write, `offline_access` (refresh).
- **Constants (client ID, URLs, callback port/path, scope names) are taken
  from the workers-sdk source at plan time — never from model memory.**
- Access + refresh tokens stored in the macOS Keychain
  (service `claude-status-light.cloudflare`). Expired access token → silent
  refresh; failed refresh → re-run browser flow.
- Risk (accepted): the client ID is wrangler's; Cloudflare offers no
  third-party OAuth registration. Documented in README. If Cloudflare ever
  revokes it, the API-token-paste flow is the planned fallback (not built now).

## Deploy engine — Cloudflare REST API, pure Swift

Sequence (all `Authorization: Bearer <access_token>`):

1. `GET /accounts` → account ID (picker if >1).
1½. `GET /accounts/{id}/workers/scripts/claude-status-relay` (or the script
   list) → does the script already exist? Determines whether step 2 includes
   the first-deploy DO migration.
2. `PUT /accounts/{id}/workers/scripts/claude-status-relay` — multipart:
   metadata JSON (main module name, compatibility date matching
   `relay/wrangler.jsonc`, Durable Object binding `RELAY` → class `RelayDO`,
   and — only when the script does not already exist — the DO migration
   creating `RelayDO` as a SQLite-backed class) + the bundled JS module.
3. Enable the script's workers.dev subdomain; read the account subdomain to
   build the URL `https://claude-status-relay.<subdomain>.workers.dev`.
4. `PUT …/secrets` with `RELAY_TOKEN`. Idempotency contract matches
   `deploy-relay.sh`: an existing token in `relay.json` is preserved so
   remote Macs stay valid; otherwise 32 random bytes hex.
5. Write `relay.json` (`url`, `token`, `host` = short hostname), mode 600.

Exact request shapes confirmed against Cloudflare's API docs during planning.

## Worker bundle — checked-in generated Swift

- `scripts/build-relay-dist.sh` (dev-side only): esbuild-bundles `relay/src`
  into one ES module, then emits
  `Sources/ClaudeStatusLight/RelayWorkerDist.swift` — a generated file holding
  the JS as a string constant plus the source-content hash it was built from.
- The generated file is committed. End users and CI never run node.
- Staleness guard: a Swift test recomputes the hash of `relay/src/*` and fails
  with "run scripts/build-relay-dist.sh" when the dist is out of date.

## New units

| Unit | Purpose |
|---|---|
| `CloudflareAuth.swift` | PKCE + browser + loopback callback + Keychain + refresh. Interface: `func accessToken() async throws -> String` |
| `CloudflareDeploy.swift` | The 5-step deploy over URLSession. Interface: `func deploy(progress: (Step) -> Void) async throws -> RelayConfig` |
| `RelayWorkerDist.swift` | generated — worker JS + source hash |
| Settings section + progress sheet | AppKit glue in `SettingsWindowController` |

Pure logic (PKCE strings, request/metadata builders, step state machine,
config write) is separated from I/O for unit testing.

## Errors

Every failure surfaces as a sentence on its step in the sheet: login declined
or timed out, callback port occupied (likely wrangler mid-login — retry after
closing it), multipart/API errors shown with Cloudflare's own message, config
write failures. Sheet footer always offers the fallback:
"CLI alternative: scripts/deploy-relay.sh".

## Testing

- Unit: PKCE verifier/challenge generation, auth-URL construction, metadata
  JSON (with/without first-run migration), secret/subdomain request bodies,
  relay.json writing, step state machine, dist staleness guard.
- Manual (user step): real browser login + real deploy from Settings — this
  doubles as the project's first genuine relay deployment; then
  `scripts/enable-cloud-hooks.sh` + env vars for a cloud repo, per README.

## Non-goals (this iteration)

- Token rotation, copy-config-for-other-Macs UI, API-token-paste fallback,
  deleting/tearing down the Worker from the app, Linux.
