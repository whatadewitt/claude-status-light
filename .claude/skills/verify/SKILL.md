---
name: verify
description: Build, launch, and observe Claude Status Light end-to-end — drive the hook with fake payloads and screenshot the menu bar / floating panel.
---

# Verifying Claude Status Light

The surface is pixels: the menu bar mascot, the floating panel, and the
dropdown menu, all fed by `hooks/status-hook.sh` writing files under
`~/.claude/status-light/sessions/`.

## Recipe

1. `swift build`, then launch `.build/debug/ClaudeStatusLight &`.
   The user's installed copy (`~/Applications/Claude Status Light.app`)
   reads the same sessions dir — leave it running; tell the instances
   apart by giving the dev build the floating panel:
   `defaults write ClaudeStatusLight showFloatingWindow -bool true`
   (unbundled dev binary uses the `ClaudeStatusLight` defaults domain;
   the installed bundle does not).
2. Drive states through the real hook with a throwaway session id:
   `printf '{"session_id":"verify-demo","cwd":"/tmp/demo"}' | bash hooks/status-hook.sh working`
   (also: `attention`, `idle`, `agent-start`, `agent-stop`, `end`;
   PreToolUse payloads carry `"tool_name":"..."`, Notification payloads
   carry `"message":"..."`).
3. Wait ~2s (1s poll timer), then screenshot. `screencapture -x` needs
   to run **unsandboxed** (sandboxed → "could not create image from
   display"). Crop the top-right with sips and upscale to read the
   18px icons:
   `sips -c 400 1400 --cropOffset 0 $((W-1400)) shot.png --out crop.png`
4. Clean up: `... | bash hooks/status-hook.sh end`, kill the dev
   instance, `defaults delete ClaudeStatusLight showFloatingWindow`.

## Gotchas

- Running hook commands from a Claude Code session updates that
  session's own light too — your real session appears in captures,
  and permission prompts flip it red mid-capture.
- Hook tests: `bash Tests/hook_test.sh`. Swift tests: `bash
  scripts/test.sh` (plain `swift test` fails to find the Testing
  framework under Command Line Tools).
