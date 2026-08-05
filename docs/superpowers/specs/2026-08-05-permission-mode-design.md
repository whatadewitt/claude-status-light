# Permission-mode indicator — design

2026-08-05. Approved in conversation (Luke). Shows which Claude Code
permission mode each session is running in (plan, auto-accept, manual, …)
on the floating panel and menu rows.

## Goal

At a glance, tell which sessions are in a non-default permission mode —
e.g. a session sitting in plan mode waiting to be flipped back, or one
running with bypassed permissions.

## Data source

Claude Code hook payloads carry a `permission_mode` string on most events:
`default`, `plan`, `acceptEdits`, `auto`, `dontAsk`, `bypassPermissions`.
Verified against https://code.claude.com/docs/en/hooks.md:

- **Carry it:** `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop` —
  all events this project registers as `working`/`idle`.
- **Lack it:** `SessionStart`, `Notification`, `SubagentStart`,
  `SubagentStop`, `SessionEnd`.
- The value is live: each event reports the mode current at fire time, so a
  mid-session shift+tab is picked up by the next event.

Inherent limitation (accepted): the mode only refreshes when a hook event
fires. Toggling modes while idle isn't visible until the next
prompt/tool-call/stop.

## 1. Hook (`hooks/status-hook.sh`)

- Extract `permission_mode` from the payload alongside the existing fields.
- **Sticky fallback**, same pattern as terminal identity: when the payload
  has no `permission_mode` but the session's state file already recorded
  one, keep the recorded value. Covers `SessionStart` and `Notification`.
- Write it into the per-session JSON as `"permission_mode"` (empty string
  when never seen).

## 2. Model (`Model.swift`)

- `SessionState` gains `permissionMode: String?` (nil when absent/empty).
- New `modeSuffix` computed property — shown **only for non-default modes**
  so the common case stays quiet:

  | payload value       | row suffix     |
  |---------------------|----------------|
  | (absent) / `default`| *(nothing)*    |
  | `plan`              | ` · plan`      |
  | `acceptEdits`       | ` · auto-edit` |
  | `auto`              | ` · auto`      |
  | `dontAsk`           | ` · don't-ask` |
  | `bypassPermissions` | ` · bypass`    |
  | anything else       | shown raw      |

  Unknown future values are displayed raw rather than hidden — new modes
  should surface, not vanish.
- Tooltip gains a `mode: <value>` line whenever the mode is known
  (including `default`), so the full truth is one hover away.

## 3. Read + display

- `StateStore.activeSessions()` parses `permission_mode` from the state
  file (missing/empty → nil).
- Row composition: `dot displayName modeSuffix shellsSuffix agentsSuffix`.
  The row string lives in the shared `SessionState` descriptors, so the
  floating panel and the menu bar dropdown both pick it up and can't drift.

## 4. Remote parity (`RemoteWire.swift`, publisher, relay)

- `WireSession` gains `var permissionMode: String?` (key
  `permission_mode`). Optional Codable keeps old publishers and relay
  snapshots decoding cleanly in both directions — no relay redeploy
  required, the field just flows through the JSON.
- Publisher fills it from the local `SessionState`; the receiving app maps
  it back in `sessionState(origin:)`.
- Cloud sessions (`WireCloudSession`) don't carry it — omitted there.

## Testing

- Unit: `modeSuffix` mapping (all six known values + unknown + nil),
  tooltip line, `StateStore` parsing (present / absent / empty).
- Unit: `WireSession` round-trip with and without the field (old-format
  JSON without the key still decodes).
- Hook: drive `status-hook.sh` with fake payloads — mode written on
  `PreToolUse`, kept sticky across a `Notification` without the field,
  overwritten by the next event that carries a different mode.
- End-to-end: the `verify` skill's fake-payload flow, eyeball the panel.

## Out of scope (YAGNI)

- No colored badge / icon treatment per mode — rows are plain text buttons;
  the text suffix matches how agents and shells already render.
- No aggregate mode signal on the menu bar icon itself.
- No polling or non-hook capture to catch idle-time mode toggles.
