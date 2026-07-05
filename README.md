# Claude Status Light

A tiny macOS menu bar light that shows what Claude Code is doing at a glance.

| Light | Meaning |
|-------|---------|
| 🟢 Green | Idle — done, ready for you |
| 🔵 Blue | Working — running tools / thinking |
| 🟡 Yellow | Needs your attention — permission prompt or notification |
| ⚪️ Gray | No active session |

Click the light for a dropdown showing every active session's state.

## How it works

```
Claude Code  ──(hooks)──▶  status-hook.sh  ──▶  ~/.claude/status-light/sessions/<id>.json
                                                          │
                                                          ▼
                                          ClaudeStatusLight.app (menu bar)
```

Claude Code fires [hooks](https://code.claude.com/docs) on lifecycle events. Each
event runs `status-hook.sh`, which records that session's current state in a small
JSON file. The menu bar app watches that folder and shows the highest-priority
state across all sessions (attention ▸ working ▸ idle), so multiple concurrent
sessions aggregate correctly.

| Hook event | State |
|------------|-------|
| `SessionStart` | idle |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | working |
| `Notification` | attention |
| `Stop` | idle |
| `SessionEnd` | (session removed) |

## Install

Requires macOS with Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone <this repo>
cd claude-status-light
./scripts/install.sh
```

The installer builds the app, installs it and the hook to `~/.claude/status-light/`,
merges the hooks into `~/.claude/settings.json` (a timestamped backup is written
first), and registers a LaunchAgent so the light runs now and at every login.

Open a fresh Claude Code session (or restart an open one) so the new hooks load.

## Uninstall

```bash
./scripts/uninstall.sh
```

Removes the LaunchAgent, strips the hooks back out of `settings.json`, and deletes
the installed files.

## Layout

```
Package.swift                     SwiftPM manifest
Sources/ClaudeStatusLight/        the menu bar app (AppKit / NSStatusBar)
hooks/status-hook.sh              records per-session state (no jq required)
scripts/install.sh                build + install + wire up
scripts/uninstall.sh              tear down
scripts/merge_settings.py         idempotent settings.json hook editor
```
