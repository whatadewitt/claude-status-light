#!/bin/bash
# Claude Code status-light hook.
#
# Usage (from settings.json):  status-hook.sh <state>
#   where <state> is one of:
#     idle | working | attention | end   — session light states
#     agent-start | agent-stop           — subagent began / finished
#
# Reads the Claude Code hook payload (JSON) on stdin, extracts the session_id
# and cwd, captures the terminal (TERM_PROGRAM + tty) it is running in and the
# PID of the Claude Code process, and writes a small per-session state file
# that the menu bar app reads. `end` removes the session's file. The recorded
# PID lets the app drop sessions whose process died without firing SessionEnd.
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

# The Notification event fires both for permission prompts (truly blocked —
# red) and for the ~60s idle reminder ("Claude is waiting for your input"),
# which just means "ready for your next prompt" — keep that one green.
if [ "$STATE" = "attention" ]; then
    MESSAGE="$(extract message | tr '[:upper:]' '[:lower:]')"
    case "$MESSAGE" in
        *"waiting for your input"*) STATE="idle" ;;
    esac
fi

# AskUserQuestion never triggers a permission prompt, so no Notification
# fires while it waits — without this, the light would sit on yellow even
# though Claude is blocked on an answer. PostToolUse flips it back to working.
if [ "$STATE" = "working" ]; then
    case "$(extract tool_name)" in
        AskUserQuestion) STATE="attention" ;;
    esac
fi

# Sanitize for use as a filename (guard against path traversal).
SAFE_ID="$(printf '%s' "$SESSION_ID" | tr -cd 'A-Za-z0-9._-')"
[ -z "$SAFE_ID" ] && SAFE_ID="default"

FILE="$DIR/$SAFE_ID.json"
AGENTS_DIR="$DIR/$SAFE_ID.agents"

# Subagent lifecycle (SubagentStart/SubagentStop events): one marker file per
# running subagent, so concurrent starts can't lose updates the way a shared
# counter would. $$ is unique among live hook processes. These events never
# touch the session state file; the app counts the markers. Ignore starts for
# unknown sessions so a surprising payload can't create ghost artifacts.
case "$STATE" in
    agent-start)
        [ -f "$FILE" ] || exit 0
        mkdir -p "$AGENTS_DIR" 2>/dev/null
        : > "$AGENTS_DIR/$$.$(date +%s)" 2>/dev/null
        exit 0
        ;;
    agent-stop)
        MARKER="$(ls "$AGENTS_DIR" 2>/dev/null | head -1)"
        [ -n "$MARKER" ] && rm -f "$AGENTS_DIR/$MARKER" 2>/dev/null
        exit 0
        ;;
esac

# A fresh session cannot have running subagents — drop leftovers from a
# previous run that reused this id (resume, or death without SessionEnd).
if [ "$(extract hook_event_name)" = "SessionStart" ]; then
    rm -rf "$AGENTS_DIR" 2>/dev/null
fi

CWD="$(extract cwd)"
[ -z "${CWD:-}" ] && CWD="$PWD"

TERM_PROG="${TERM_PROGRAM:-unknown}"

# Nearest non-shell ancestor: the Claude Code process that spawned this hook
# (hooks may run through one or more intermediate shells). Prints nothing if
# it can't be identified.
find_claude_pid() {
    local p=$$ comm base _
    for _ in 1 2 3 4 5 6 7 8; do
        p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d '[:space:]')"
        case "$p" in ''|0|1) return ;; esac
        comm="$(ps -o comm= -p "$p" 2>/dev/null | tr -d '[:space:]')"
        base="${comm##*/}"
        base="${base#-}"
        case "$base" in
            sh|bash|zsh|dash|ksh|fish) continue ;;
            *) printf '%s' "$p"; return ;;
        esac
    done
}
CLAUDE_PID="$(find_claude_pid)"

# Controlling terminal of the Claude process (the hook itself often has none).
TTY_DEV="$(ps -o tty= -p "${CLAUDE_PID:-$$}" 2>/dev/null | tr -d '[:space:]')"
case "$TTY_DEV" in
    ""|"?"|"??") TTY_PATH="" ;;
    /dev/*)      TTY_PATH="$TTY_DEV" ;;
    *)           TTY_PATH="/dev/$TTY_DEV" ;;
esac

if [ "$STATE" = "end" ]; then
    rm -f "$FILE" 2>/dev/null
    rm -rf "$AGENTS_DIR" 2>/dev/null
else
    # Minimal JSON string escaping (backslash then quote).
    esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    printf '{"state":"%s","session_id":"%s","cwd":"%s","term_program":"%s","tty":"%s","pid":%d,"updated_at":%s}\n' \
        "$STATE" \
        "$(esc "$SESSION_ID")" \
        "$(esc "$CWD")" \
        "$(esc "$TERM_PROG")" \
        "$(esc "$TTY_PATH")" \
        "${CLAUDE_PID:-0}" \
        "$(date +%s)" \
        > "$FILE" 2>/dev/null
fi

exit 0
