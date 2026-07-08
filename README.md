# Claude Status Light

A tiny macOS menu bar stoplight that shows what Claude Code is doing at a glance.

| Light | Meaning |
|-------|---------|
| ⚪️ Off | Not running — no active session |
| 🔴 Red | Waiting for your input — permission prompt or a question from Claude |
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

By default it's the Claude Code pixel mascot, tinted to the state color.
Drop an image at `~/.claude/status-light/icon.png` to use custom artwork
instead — the app draws the full-color artwork and adds a
small stoplight status dot in the corner, so the mark stays recognizable while
still showing state. Use **Set custom icon…** (in the menu) or **Reveal icon
folder…** (in Settings) to open that folder in Finder.

## Subagents

When any session has subagents running, the icon gains a small blue count
badge (blue on purpose — it's activity, not a stoplight state), and that
session's row in the menu and floating window reads "· N agents".

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
terminal it's running in (`$TERM_PROGRAM` and tty) so the app can focus it, and the
Claude Code process's PID — in a small JSON file. The menu bar app watches that
folder and shows the highest-priority state across all sessions, so multiple
concurrent sessions aggregate correctly.

The recorded PID keeps the list honest: if a session's process is gone (terminal
closed, crash — anything that skips `SessionEnd`), the app drops it immediately and
deletes its file. Headless sessions with no terminal (e.g. daemon-spawned background
agents) are real and still counted; the session list shows what each one is working
on — its task title, read from the transcript path the hook records (e.g.
`mlb-props · Improve system win rate from 59%`) — falling back to `(bg)` for
untitled ones like pre-warmed spares. Terminal identity is sticky: daemon
processes may fire events for an interactive session, and their missing tty
must not strip the session's recorded terminal.

| Hook event | State | Light |
|------------|-------|-------|
| `SessionStart` | idle | 🟢 awaiting next task |
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | working | 🟡 running |
| `Notification` | attention | 🔴 waiting for input |
| `Stop` | idle | 🟢 awaiting next task |
| `SubagentStart` / `SubagentStop` | agent-start / agent-stop | 🔵 subagent count badge |
| `SessionEnd` | — | (session removed) |

Two classifications happen inside the hook rather than the table: the ~60s
"Claude is waiting for your input" reminder notification is kept 🟢 (it just
means "ready for your next prompt"), and a `PreToolUse` for `AskUserQuestion`
is upgraded to 🔴 — Claude is blocked on your answer, but no permission
notification ever fires for it. Subagent starts and stops maintain one marker
file each next to the session's JSON; the app counts them for the badge.

## Install

Requires macOS with Xcode or the Command Line Tools (`xcode-select --install`).

```bash
git clone <this repo>
cd claude-status-light
./scripts/install.sh
```

The installer builds the app, assembles a proper **`Claude Status Light.app`**
bundle in `~/Applications` (with a generated icon), installs the hook to
`~/.claude/status-light/`, merges the hooks into `~/.claude/settings.json` (a
timestamped backup is written first), and registers a **login item** so it runs
now and at every login.

> On first install macOS may ask permission to control **System Events** (to add
> the login item) — that's expected; approve it once. The app is built locally
> and unsigned, so it runs without a Gatekeeper prompt.

Open a fresh Claude Code session (or restart an open one) so the new hooks load.

## Uninstall

```bash
./scripts/uninstall.sh
```

Quits the app, removes the login item, strips the hooks back out of
`settings.json`, and deletes the app bundle and installed files.

## Layout

```
Package.swift                     SwiftPM manifest
Sources/ClaudeStatusLight/
  main.swift                      entry point (+ hidden --render-iconset mode)
  AppDelegate.swift               ties the surfaces together; polls + watches state
  Model.swift                     LightState + SessionState
  StateStore.swift                reads/aggregates per-session state files
  Settings.swift                  UserDefaults-backed preferences
  StatusBarController.swift       menu bar item
  FloatingPanelController.swift   always-on-top desktop window
  SettingsWindowController.swift  preferences window
  IconRenderer.swift              spark/mascot icon + .icns generation
  TerminalFocuser.swift           click-a-session → focus its terminal
  Controls.swift                  small AppKit target/action helpers
hooks/status-hook.sh              records per-session state (no jq required)
scripts/install.sh                build + bundle .app + login item + wire up
scripts/uninstall.sh              tear down
scripts/merge_settings.py         idempotent settings.json hook editor
```
