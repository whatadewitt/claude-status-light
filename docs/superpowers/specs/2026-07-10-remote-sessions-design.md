# Remote sessions

2026-07-10 · approved by Luke

## Problem

The app only sees sessions on this Mac: hooks write local files, liveness is
a local PID check, shells come from the local process table. Sessions on
other machines (home Macs, the office mini reached over SSH) and cloud
sessions (claude.ai/code, desktop-app cloud sandboxes) are invisible.

Platform facts that shape the design (verified against current docs):

- Cloud sandboxes run hooks, but **only from the repo's committed
  `.claude/settings.json`** — `~/.claude/settings.json` never syncs there.
  `CLAUDE_CODE_REMOTE=true` marks the environment.
- Cloud hooks can make outbound HTTPS, subject to a **per-environment domain
  allowlist** (custom domains addable). Environment variables set in the
  cloud environment config propagate to hooks.
- There is **no API to enumerate a user's claude.ai/web sessions** (the
  Sessions API covers only the separate Managed Agents product). Push from
  hooks is the only channel.

Audience: Luke now, shareable later — each user deploys their own relay; the
setup path must be scriptable and documented.

## Architecture

```
office-mini / other Macs                     cloud sandboxes (web/desktop)
  hooks → local files (unchanged)              repo-committed hook → POST raw
  claude-status-light --publish                payload on every event
  (launchd, reuses StateStore)                          │
        │  POST /hosts/<name>  snapshot                 ▼
        └──────────────► Cloudflare Worker + one Durable Object
                                  ▲          (classification server-side)
                                  │  GET /sessions  (poll ~4s)
                       status-light Mac (menu bar app)
```

One Worker fronting **one Durable Object as the store**. Not KV: KV is
eventually consistent (up to ~60s cross-edge propagation) and the writers
and reader hit different edges. The DO gives strong consistency and is the
natural later upgrade point for WebSocket push; for now it is plain HTTP
handlers.

Endpoints, all requiring one bearer token (a Worker secret; clients read it
from `~/.claude/status-light/relay.json`, chmod 600):

- `POST /hosts/:name` — publisher upsert. Body is the host's **complete
  snapshot** of derived `SessionState` JSON (states, titles, shells,
  subagent counts). Snapshot-replace semantics: a session absent from the
  next snapshot is gone; the snapshot itself is the host's heartbeat.
- `POST /hook` — cloud ingestion. Raw Claude Code hook payload; the Worker
  replicates the shell hook's classifications (idle-reminder Notification
  stays green, `PreToolUse` + `AskUserQuestion` upgrades to red, `Stop` →
  green, `SessionEnd` deletes, `SubagentStart/Stop` maintain a count).
  Session key = `session_id`; label = cwd basename (repo name).
- `GET /sessions` — everything, each entry stamped with the DO's
  `received_at` for staleness math (client clocks never matter).

## Liveness (differs by class, honestly)

- **Host sessions** inherit real PID/shell truth from the publisher. A host
  that stops snapshotting for ~60s is offline → its rows drop.
- **Cloud sessions** have no heartbeat: removed on `SessionEnd` or after
  ~30 min without events. A parked-but-alive cloud session eventually
  fades — accepted trade-off, consistent with parked-agent dimming.

Enforcement: the app filters on `received_at` at read time (it owns the
thresholds); the DO additionally prunes expired entries lazily on read so
storage stays bounded. Neither side trusts client clocks.

## Publisher

`claude-status-light --publish`: headless mode of the existing binary (no
AppKit surfaces) running the same `StateStore.activeSessions()` loop, so PID
liveness, shell scanning, subagent counts, and transcript titles come free.
Pushes on change and at least every ~15s; quiet through network failures
(retry next tick, never crash-loop). `scripts/install-publisher.sh` sets up
a remote Mac: build, create `relay.json` (url, token, host label defaulting
to hostname), install a launchd agent. The status-light Mac does not publish
(its sessions are already local). Non-Mac machines: future — they can use
the cloud-style direct path.

## Cloud hook

A `command`-type hook entry plus a tiny committed script
(`.claude/status-relay.sh`) in each covered repo. The script no-ops unless
`CLAUDE_CODE_REMOTE=true` (inert on all local machines), otherwise:

```sh
curl -m 2 --data @- "$STATUS_LIGHT_RELAY_URL/hook" \
  -H "Authorization: Bearer $STATUS_LIGHT_RELAY_TOKEN" &
```

URL and token come from env vars in the Claude Code cloud environment
config — nothing secret is committed. One-time setup per environment: add
the two env vars, allowlist the Worker's domain.
`scripts/enable-cloud-hooks.sh` stamps the hook entries + script into a repo.

Limitation (platform, not choice): cloud coverage is per-repo and
per-environment; a cloud session in an unhooked repo is invisible.

## App side

`RemoteStore` polls `GET /sessions` every ~4s on a background queue and
caches the latest result; `AppDelegate` merges with local `StateStore` into
every surface. `SessionState` gains `origin: String?` (`nil` = local, else
host label or `cloud`). No `relay.json` → `RemoteStore` never starts; app
behaves exactly as today.

- **Display:** remote rows read `office-mini · mlb-props · <title>`; cloud
  rows `cloud · <repo>`. Remote sessions participate fully in the aggregate
  light. Parked-agent dimming applies by the same rule.
- **Interaction:** remote rows are disabled (no tty to focus), tooltip shows
  host, cwd, last-update age.
- **Staleness UI:** when the app can't reach the Worker, remote rows age out
  and the menu footer shows a quiet `relay unreachable` line, so "no remote
  rows" and "can't see remote" are distinguishable.

## Security

One bearer token, generated at deploy (`wrangler secret`), required
everywhere. Compromise is bounded to reading/spoofing status states.
HTTPS-only; token never in a repo; rotation = update secret + `relay.json`
+ environment config.

## Failure modes

- Publisher can't reach Worker → rows vanish after the staleness window
  (fail-invisible, never fail-stale-green).
- Worker down → app keeps local behavior + `relay unreachable` footer.
- Cloud curl timeout (2s, backgrounded) → state lags one event; the next
  event catches up.

## Testing

- Worker (vitest): classification table (idle-reminder, AskUserQuestion
  upgrade, subagent counting, SessionEnd), snapshot-replace semantics,
  auth rejection, TTL expiry.
- Swift: `RemoteStore` parsing/staleness against a stubbed HTTP layer;
  merge/aggregate tests extending existing `StateStore` patterns.
- End-to-end: `verify` skill flow + `wrangler dev` local Worker + fake
  payloads, screenshotting a merged menu.

## Future work

- Tailscale Funnel as an alternative relay (state never leaves owned
  machines; no cloud-session coverage on that path).
- WebSocket push from the DO (sub-second updates) replacing polling.
- "SSH to session" click action for remote host rows.
- Linux publisher (or documented direct-POST fallback).
- Optional setting to exclude remote sessions from the aggregate light.
