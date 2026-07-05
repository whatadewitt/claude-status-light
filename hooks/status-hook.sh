#!/bin/bash
# Claude Code status-light hook.
#
# Usage (from settings.json):  status-hook.sh <state>
#   where <state> is one of: idle | working | attention | end
#
# Reads the Claude Code hook payload (JSON) on stdin, extracts the session_id
# and cwd, captures the terminal (TERM_PROGRAM + tty) it is running in, and
# writes a small per-session state file that the menu bar app reads. `end`
# removes the session's file.
#
# Must always exit 0 and never block — it runs inline in Claude Code.

set -u

STATE="${1:-idle}"
DIR="$HOME/.claude/status-light/sessions"
mkdir -p "$DIR" 2>/dev/null

# Slurp the hook payload from stdin (may be empty).
INPUT="$(cat 2>/dev/null || true)"

# Pull "key":"value" out of the payload without requiring jq.
extract() {
    printf '%s' "$INPUT" \
        | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
        | head -1 \
        | sed 's/.*"\([^"]*\)"[[:space:]]*$/\1/'
}

SESSION_ID="$(extract session_id)"
[ -z "${SESSION_ID:-}" ] && SESSION_ID="default"

# Sanitize for use as a filename (guard against path traversal).
SAFE_ID="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
[ -z "$SAFE_ID" ] && SAFE_ID="default"

CWD="$(extract cwd)"
[ -z "${CWD:-}" ] && CWD="$PWD"

TERM_PROG="${TERM_PROGRAM:-unknown}"

# Controlling terminal of this session (inherited from Claude Code).
TTY_DEV="$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')"
case "$TTY_DEV" in
    ""|"?"|"??") TTY_PATH="" ;;
    /dev/*)      TTY_PATH="$TTY_DEV" ;;
    *)           TTY_PATH="/dev/$TTY_DEV" ;;
esac

FILE="$DIR/$SAFE_ID.json"

if [ "$STATE" = "end" ]; then
    rm -f "$FILE" 2>/dev/null
else
    # Minimal JSON string escaping (backslash then quote).
    esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    printf '{"state":"%s","session_id":"%s","cwd":"%s","term_program":"%s","tty":"%s","updated_at":%s}\n' \
        "$STATE" \
        "$(esc "$SESSION_ID")" \
        "$(esc "$CWD")" \
        "$(esc "$TERM_PROG")" \
        "$(esc "$TTY_PATH")" \
        "$(date +%s)" \
        > "$FILE" 2>/dev/null
fi

exit 0
