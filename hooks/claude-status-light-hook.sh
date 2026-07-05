#!/bin/sh
#
# Claude Code status-light hook.
#
# Usage:  claude-status-light-hook.sh <state> [detail]
#   <state>   one of: idle | working | waiting | error
#   [detail]  optional short text shown in the menu-bar dropdown
#
# Claude Code invokes this from settings.json hooks and pipes a JSON event on
# stdin. We pull `cwd` out of that JSON (best effort, no jq dependency) and
# write ~/.claude/status-light.json atomically so the menu-bar app never reads
# a partially written file.

set -eu

STATE="${1:-idle}"
DETAIL="${2:-}"

DIR="$HOME/.claude"
FILE="$DIR/status-light.json"
mkdir -p "$DIR"

# Read the hook event JSON from stdin (may be empty when run manually).
INPUT="$(cat 2>/dev/null || true)"

# Best-effort extraction of "cwd":"…" without requiring jq.
CWD="$(printf '%s' "$INPUT" \
    | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    | head -n1)"

TS="$(date +%s)"

# Escape backslashes and double quotes so we emit valid JSON.
esc() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}
STATE_E="$(esc "$STATE")"
DETAIL_E="$(esc "$DETAIL")"
CWD_E="$(esc "$CWD")"

TMP="$(mktemp "$DIR/.status-light.XXXXXX")"
printf '{"state":"%s","detail":"%s","cwd":"%s","ts":%s}\n' \
    "$STATE_E" "$DETAIL_E" "$CWD_E" "$TS" > "$TMP"
mv -f "$TMP" "$FILE"

# Hooks must not block Claude; always succeed.
exit 0
