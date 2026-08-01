#!/bin/sh
#
# claude-status.sh — report a Claude Code session's status to the menu bar app.
#
# Usage:  claude-status.sh <status>
#   where <status> is one of: idle | working | waiting | end
#
# Claude Code invokes this from a hook and passes the hook payload as JSON on
# stdin. We pull `session_id` out of that payload and write a tiny per-session
# state file that the ClaudeStatusLight menu bar app reads and aggregates.
#
#   working  -> a tool is running / Claude is generating   (yellow)
#   waiting  -> Claude needs your input or a permission     (red)
#   idle     -> the turn finished, waiting on your prompt   (green)
#   end      -> the session ended; remove its state file
#
# Dependency-free: no jq / python required. Works with the default macOS /bin/sh.

set -u

status="${1:-}"
case "$status" in
  idle|working|waiting|end) ;;
  *)
    echo "claude-status.sh: unknown status '${status}' (expected idle|working|waiting|end)" >&2
    exit 2
    ;;
esac

# Where per-session state lives. Keep this in sync with StatusStore.swift.
state_dir="${CLAUDE_STATUS_LIGHT_DIR:-$HOME/.claude/status-light/sessions}"

# Read the hook payload from stdin (may be empty if run manually).
payload="$(cat 2>/dev/null || true)"

# Extract "session_id": "<value>" without a JSON parser. Session ids are
# UUID-style with no quotes/commas inside, so a scoped grep is safe.
session_id="$(
  printf '%s' "$payload" \
    | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n 1 \
    | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/'
)"

# Fall back to a stable per-terminal id so the tool still works when run
# manually or if the payload ever lacks a session_id.
if [ -z "$session_id" ]; then
  session_id="local-$(id -u)-$PPID"
fi

# Sanitize: allow only characters that are safe in a filename.
session_id="$(printf '%s' "$session_id" | tr -c 'A-Za-z0-9._-' '_')"

if [ "$status" = "end" ]; then
  rm -f "$state_dir/$session_id.json" 2>/dev/null || true
  exit 0
fi

mkdir -p "$state_dir" 2>/dev/null || true

now="$(date +%s)"
tmp="$state_dir/.$session_id.$$.tmp"

# Write then atomically rename so the app never reads a half-written file.
printf '{"status":"%s","updatedAt":%s,"sessionId":"%s"}\n' \
  "$status" "$now" "$session_id" > "$tmp" 2>/dev/null || exit 0
mv -f "$tmp" "$state_dir/$session_id.json" 2>/dev/null || rm -f "$tmp"

exit 0
