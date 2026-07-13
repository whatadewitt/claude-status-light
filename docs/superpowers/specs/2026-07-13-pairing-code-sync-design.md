# Pairing-code sync for other machines — design

2026-07-13. Approved in conversation (Luke). Replaces the hand-copy of
`~/.claude/status-light/relay.json` when setting up another Mac.

## Goal

From a configured Mac, generate a short-lived pairing code; on the other Mac,
one command fetches the relay config and installs the publisher. No Cloudflare
login, no scp, no hand-editing the `host` field.

## Why not the obvious alternatives

- Fetching the config from the Worker directly is a bootstrap paradox: the
  bearer token is both the payload and the only credential.
- Logging into Cloudflare on the second Mac can't retrieve the existing
  secret (write-only API) and re-deploying would rotate it, breaking the
  first Mac.
- iCloud Keychain sync needs entitlements an unsigned local build lacks.

## 1. Relay (TypeScript — same Worker/DO, two new routes)

- `POST /pair` — bearer-authed like every existing route. The DO generates a
  128-bit random code (32 hex chars), stores the caller-supplied config
  `{url, token}` under it with a **10-minute TTL**, returns
  `{code, expires_at}`.
- `GET /pair/:code` — unauthenticated by necessity. Returns the config
  **exactly once** (delete-on-read). Unknown, expired, and already-used codes
  are indistinguishable: uniform 404, no oracle.
- 128-bit codes make brute force a non-issue → no rate limiting. Expired
  codes pruned lazily, same pattern as existing snapshot pruning.
- Vitest coverage: round trip; single-use (second GET 404s); expiry; 404
  uniformity; `/pair` state never leaks into `/sessions` responses.

## 2. Sending side (Swift — Settings)

- Second button in the Remote sessions section, **"Pair another machine…"**,
  visible only when `RelayConfig.load()` is non-nil.
- POSTs to `/pair` with the existing relay bearer token (no Cloudflare auth
  involved). Shows a small sheet containing the exact command to paste on the
  other machine:
  `scripts/install-publisher.sh --pair <url> <code>`
  with a Copy button and the line "expires in 10 minutes, works once".
- Pure parts (request builder, response model, command-string formatting) are
  unit-tested; the sheet is AppKit glue following the existing
  DeployProgressSheet/ClosureInvoker patterns.

## 3. Receiving side (bash — install-publisher.sh)

- New flag: `--pair <url> <code>`. Curls `GET <url>/pair/<code>`; on 200
  writes `~/.claude/status-light/relay.json` (mode 600) with `host` replaced
  by the **local** short hostname (kills today's hand-edit step), then falls
  through to the existing build + launchd path.
- On 404: exit 1 with "code expired or already used — generate a new one
  from Settings on your main Mac."
- Covered by the script's smoke checks (bash -n; inert/error paths) plus the
  relay-side tests above.

## Non-goals

- Pairing for cloud repos (they use env vars, not relay.json).
- Revoking pairs (nothing persists server-side after fetch or expiry).
- First-launch pairing prompt in the app for viewer Macs (TODO.md notes it).

## Constraints / notes

- The receiving Mac still needs this repo cloned (install-publisher.sh builds
  the binary from source) — "one SSH command" means "clone + one command",
  unchanged from today.
- Regenerate `RelayWorkerDist.swift` (scripts/build-relay-dist.sh) after any
  relay/src change, or RelayWorkerDistTests fails the build — the in-app
  deploy ships the bundled Worker, so the pairing routes MUST land in the
  generated bundle too.
- Prerequisite reality check: the first real in-app deploy (Settings → Set up
  Cloudflare relay…) has not been exercised yet as of this writing; test it
  before or alongside this feature.
