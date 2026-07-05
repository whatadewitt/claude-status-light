#!/bin/bash
# Claude Code status-light hook.
#
# Usage (from settings.json):  status-hook.sh <state>
#   where <state> is one of: idle | working | attention | end
#
# Reads the Claude Code hook payload (JSON) on stdin, extracts the
# session_id, and writes a small per-session state file that the menu
# bar app reads. `end` removes the session's file.
#
# Must always exit 0 and never block — it runs inline in Claude Code.

set -u

STATE="${1:-idle}"
DIR="$HOME/.claude/status-light/sessions"
mkdir -p "$DIR" 2>/dev/null

# Slurp the hook payload from stdin (may be empty).
INPUT="$(cat 2>/dev/null || true)"

# Extract "session_id":"..." without requiring jq.
SESSION_ID="$(printf '%s' "$INPUT" \
    | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 \
    | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/')"
[ -z "${SESSION_ID:-}" ] && SESSION_ID="default"

# Guard against path traversal from an unexpected id.
SESSION_ID="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
[ -z "$SESSION_ID" ] && SESSION_ID="default"

FILE="$DIR/$SESSION_ID.json"

if [ "$STATE" = "end" ]; then
    rm -f "$FILE" 2>/dev/null
else
    printf '{"state":"%s","session_id":"%s","updated_at":%s}\n' \
        "$STATE" "$SESSION_ID" "$(date +%s)" > "$FILE" 2>/dev/null
fi

exit 0
