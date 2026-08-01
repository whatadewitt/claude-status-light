# Claude Status Light

A tiny colored dot in your Mac menu bar that shows what Claude Code is doing.

| Color | Meaning |
|-------|---------|
| 🟢 Green | **Idle** — waiting for your next prompt |
| 🟡 Yellow | **Working** — running a tool or generating |
| 🔴 Red | **Needs your input** — a permission prompt or notification is waiting |
| ⚫️ Dim | No active Claude Code sessions |

It's **multi-session aware**: if you have several `claude` sessions running, the
dot shows the most urgent state (red > yellow > green), and the dropdown lists
each session individually.

## How it works

```
  Claude Code                     A tiny state file            Menu bar app
  ───────────                     per session                  ────────────
  hook fires  ──►  claude-status.sh  ──►  ~/.claude/status-light/  ──►  reads &
  (PreToolUse,     writes {status}        sessions/<id>.json            aggregates,
   Stop, …)                                                             draws the dot
```

1. **Claude Code hooks** fire on lifecycle events (`PreToolUse`, `Stop`,
   `Notification`, …). Each runs `claude-status.sh <status>`, which writes a
   small JSON file for that session.
2. The **menu bar app** (native Swift, no dependencies) polls that directory
   once a second, aggregates all live sessions, and colors the dot.

No network, no daemon, no polling of Claude itself — just a few tiny files.

## Install

Requires the Xcode Command Line Tools (`xcode-select --install`).

```sh
# 1. Build the menu bar app  ->  build/ClaudeStatusLight.app
scripts/build-app.sh

# 2. Wire up the Claude Code hooks (merges into ~/.claude/settings.json)
scripts/install-hooks.sh

# 3. Launch it
open build/ClaudeStatusLight.app
```

Then **restart any running `claude` sessions** so they pick up the new hooks.
The dot appears in your menu bar immediately (dim until a session reports in).

### Make it permanent

- **Install:** `cp -R build/ClaudeStatusLight.app /Applications/`
- **Start at login:** System Settings → General → Login Items → **+** →
  choose ClaudeStatusLight.

### Per-project hooks

By default the installer edits `~/.claude/settings.json`, which applies to all
projects. To scope it to one project instead, point it at that project's file:

```sh
scripts/install-hooks.sh /path/to/project/.claude/settings.json
```

## Uninstall

```sh
scripts/uninstall-hooks.sh          # removes only this tool's hooks
```

Then quit the app from its menu bar dropdown. It removes only the entries it
added; your other hooks in `settings.json` are left untouched.

## Layout

```
app/                     Swift menu bar app (SwiftPM)
  Sources/ClaudeStatusLight/
    main.swift           App entry point (accessory / menu-bar-only)
    AppDelegate.swift    Status item, colored dot, dropdown, 1s poll
    Status.swift         Status enum: colors, labels, priority
    StatusStore.swift    Reads & aggregates per-session state files
hooks/
  claude-status.sh       Dependency-free hook script (writes state)
  settings.snippet.json  Manual-merge fallback for settings.json
scripts/
  build-app.sh           Compile + wrap into a .app bundle
  install-hooks.sh       Install script + merge hooks into settings.json
  uninstall-hooks.sh     Remove this tool's hooks + state
```

## Customize

- **Colors:** edit `color` in `app/Sources/ClaudeStatusLight/Status.swift`.
- **Which events map to which state:** edit the `mapping` in
  `scripts/install-hooks.sh` (then re-run it).
- **State directory:** set `CLAUDE_STATUS_LIGHT_DIR` — both the hook script and
  the app honor it (handy for testing).

## Testing without Claude Code

You can drive the light by hand:

```sh
export CLAUDE_STATUS_LIGHT_DIR="$HOME/.claude/status-light/sessions"
echo '{"session_id":"demo"}' | hooks/claude-status.sh working   # dot -> yellow
echo '{"session_id":"demo"}' | hooks/claude-status.sh waiting   # dot -> red
echo '{"session_id":"demo"}' | hooks/claude-status.sh end       # session cleared
```
