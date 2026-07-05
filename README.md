# Claude Status Light

A tiny macOS menu bar stoplight that shows what Claude Code is doing at a glance.

| Light | Meaning |
|-------|---------|
| ⚪️ Off | Not running — no active session |
| 🔴 Red | Waiting for your input — permission prompt / notification |
| 🟡 Yellow | Running — tools / thinking |
| 🟢 Green | Awaiting your next task (done) |

Click the light for a dropdown listing every active session. **Click a session
to jump straight to its terminal window** — handy when you have several Claude
Code instances open at once. Terminal.app and iTerm2 are focused by their exact
tab (matched by tty); other terminals are brought to the front best-effort.

When multiple sessions are active, the single light shows the most urgent state:
red (blocked on you) ▸ green (done, wants a task) ▸ yellow (busy).

## How it works

```
Claude Code  ──(hooks)──▶  status-hook.sh  ──▶  ~/.claude/status-light/sessions/<id>.json
                                                          │
                                                          ▼
                                          ClaudeStatusLight.app (menu bar)
```

Claude Code fires [hooks](https://code.claude.com/docs) on lifecycle events. Each
event runs `status-hook.sh`, which records that session's current state — plus the
terminal it's running in (`$TERM_PROGRAM` and tty) so the app can focus it — in a
small JSON file. The menu bar app watches that folder and shows the highest-priority
state across all sessions, so multiple concurrent sessions aggregate correctly.

| Hook event | State | Light |
|------------|-------|-------|
| `SessionStart` | idle | 🟢 awaiting next task |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | working | 🟡 running |
| `Notification` | attention | 🔴 waiting for input |
| `Stop` | idle | 🟢 awaiting next task |
| `SessionEnd` | — | (session removed) |

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
