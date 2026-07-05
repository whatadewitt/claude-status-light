# Claude Status Light

A tiny macOS menu bar stoplight that shows what Claude Code is doing at a glance.

| Light | Meaning |
|-------|---------|
| ⚪️ Off | Not running — no active session |
| 🔴 Red | Waiting for your input — permission prompt / notification |
| 🟡 Yellow | Running — tools / thinking |
| 🟢 Green | Awaiting your next task (done) |

## Where it shows up

Three surfaces, each toggleable in **Settings** (open it from any menu):

- **Menu bar icon** (default on) — the light in the top-right status bar.
- **Floating desktop window** — a small always-on-top panel that mirrors the
  status and lists sessions. Lock it to any screen corner, or unlock it to drag
  it anywhere (its position is remembered).
- **Dock icon** — the app icon itself tints to the current state.

Enabling the dock icon switches the app to a regular (dock-present) app;
otherwise it runs as a menu-bar/desktop agent with no dock presence.

## The icon

By default it's a Claude-style radial "spark" that tints to the state color.
Drop an image at `~/.claude/status-light/icon.png` (for example the Claude
mascot) to use it instead — the app draws the full-color artwork and adds a
small stoplight status dot in the corner, so the mark stays recognizable while
still showing state.

## Jumping to a session's terminal

Click the menu-bar light (or a row in the floating window) to list every active
session, and **click one to jump straight to its terminal** — handy with several
Claude Code instances open at once:

- **iTerm2** and **Terminal.app** — focused by their exact tab (matched by tty).
- **Ghostty** and everything else — brought to the front (these terminals don't
  expose per-tab tty to AppleScript, so tab-level targeting isn't possible).

When multiple sessions are active, the single light shows the most urgent state:
red (blocked on you) ▸ green (done, wants a task) ▸ yellow (busy). That last
ranking is a setting you can flip.

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
