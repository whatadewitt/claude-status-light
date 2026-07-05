# Claude Status Light

A tiny macOS menu-bar light that shows what Claude Code is doing at a glance.

| Dot | State | Meaning |
|-----|-------|---------|
| ⚪️ grey | `idle` | No active work — Claude is done or waiting for a new prompt |
| 🔵 blue *(pulsing)* | `working` | Claude is actively working on your request |
| 🟢 green | `waiting` | Claude needs you — a permission prompt or your input |
| 🔴 red | `error` | Something went wrong (optional; not wired by default) |

Click the dot for a dropdown showing the current state, an optional detail
line, and the working directory of the session that last updated it.

## How it works

Claude Code fires [hooks](https://docs.claude.com/en/docs/claude-code/hooks) as
it runs. Each hook calls a small shell script that writes the current state to
`~/.claude/status-light.json` (atomically). The menu-bar app watches that file
and recolors its dot.

```
Claude Code hook ──▶ claude-status-light-hook.sh ──▶ ~/.claude/status-light.json ──▶ menu-bar app
```

## Requirements

- macOS 12 (Monterey) or newer
- The Swift toolchain (comes with the [Xcode Command Line
  Tools](https://developer.apple.com/xcode/): `xcode-select --install`)

No Xcode project and no third-party libraries — it's a plain Swift Package.

## Install

```sh
git clone https://github.com/whatadewitt/claude-status-light.git
cd claude-status-light
./scripts/install.sh
```

The installer builds the app, copies it to `/Applications`, installs the hook
script, merges the hooks into `~/.claude/settings.json` (leaving any existing
hooks untouched), and launches it. A grey dot should appear in your menu bar.

To have it start automatically on login: **System Settings → General → Login
Items →** add **ClaudeStatusLight**.

## Try it without Claude

Any state can be set by hand — handy for confirming the light works:

```sh
~/.claude/claude-status-light-hook.sh working "manual test"
~/.claude/claude-status-light-hook.sh waiting
~/.claude/claude-status-light-hook.sh idle
```

## Manual setup (if you prefer)

1. Build the app bundle:
   ```sh
   ./scripts/make-app.sh
   cp -R build/ClaudeStatusLight.app /Applications/
   open /Applications/ClaudeStatusLight.app
   ```
2. Install the hook script:
   ```sh
   cp hooks/claude-status-light-hook.sh ~/.claude/
   chmod +x ~/.claude/claude-status-light-hook.sh
   ```
3. Merge the contents of [`hooks/settings-snippet.json`](hooks/settings-snippet.json)
   into `~/.claude/settings.json`.

## Customizing

- **Colors / states** — edit the `ClaudeState` enum in
  [`Sources/ClaudeStatusLight/main.swift`](Sources/ClaudeStatusLight/main.swift),
  then re-run `./scripts/make-app.sh`.
- **Which hooks map to which state** — edit
  [`hooks/settings-snippet.json`](hooks/settings-snippet.json). See the
  [hooks reference](https://docs.claude.com/en/docs/claude-code/hooks) for the
  full list of events (`PreToolUse`, `PostToolUse`, `SubagentStop`, …).

## Uninstall

```sh
rm -rf /Applications/ClaudeStatusLight.app
rm ~/.claude/claude-status-light-hook.sh ~/.claude/status-light.json
```

Then remove the `claude-status-light-hook.sh` entries from
`~/.claude/settings.json`.
