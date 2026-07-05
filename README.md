# Claude Status Light

A tiny macOS menu-bar light that shows what Claude Code is doing at a glance:

| Light | State | Meaning |
|-------|-------|---------|
| 🟢 Green | `idle` | Session ready, nothing running |
| 🟡 Yellow | `working` | Claude is thinking or running tools |
| 🔴 Red (pulsing) | `attention` | Claude needs you — a permission prompt or a question |
| ⚪️ Gray | `unknown` | No recent activity / app just launched |

Click the icon for the current state, the last tool that ran, when it updated,
and a quit option.

## How it works

Claude Code fires [hooks](https://docs.claude.com/en/docs/claude-code/hooks) on
lifecycle events. Small hook commands write the current state to
`~/.claude/status-light/state.json`. A native Swift menu-bar app watches that
file and colors its dot accordingly.

```
Claude Code event ──► hook ──► claude-status ──► state.json ──► menu-bar app
```

- `SessionStart`, `Stop`, `SessionEnd` → **idle**
- `UserPromptSubmit`, `PreToolUse` → **working**
- `Notification` (permission / waiting on you) → **attention**

## Install

Requires macOS 11+ and the Xcode command line tools (`xcode-select --install`).

```bash
# 1. Wire the hooks into Claude Code (backs up your settings.json first)
./install-hooks.sh

# 2. Build the menu-bar app
./build.sh

# 3. Launch it
open build/ClaudeStatusLight.app
```

Restart any open Claude Code sessions after step 1 so the new hooks load.

To launch the app automatically, add `ClaudeStatusLight.app` under
**System Settings → General → Login Items**.

## Try it without Claude Code

The app reads a plain file, so you can drive it by hand:

```bash
bin/claude-status set working "Running tests"
bin/claude-status set attention "Waiting for permission"
bin/claude-status set idle
bin/claude-status get
```

Point the app at a different file with the `CLAUDE_STATUS_FILE` environment
variable (the helper honors it too).

## Notes & limitations

- **One global light.** State is a single file, so if you run several Claude
  Code sessions at once the light reflects whichever most recently fired an
  event. Per-session lights would need a richer state file and menu.
- **Polling.** The app polls the state file twice a second — instant in
  practice, negligible cost, and simpler than a file watcher.
- The app is unsigned; on first launch macOS may ask you to confirm it in
  **System Settings → Privacy & Security**.

## Layout

```
Sources/main.swift            The menu-bar app (AppKit, ~200 lines)
bin/claude-status             Shell helper that writes state.json
hooks/settings.snippet.json   Hook config merged into ~/.claude/settings.json
build.sh                      Compiles the .app bundle
install-hooks.sh              Installs the helper and merges the hooks
```
