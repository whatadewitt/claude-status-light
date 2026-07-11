#!/bin/bash
# Claude Status Light cloud relay hook.
#
# Committed into a repo as .claude/status-relay.sh so Claude Code cloud
# sandboxes (claude.ai/code, desktop-app cloud sessions) can report their
# lifecycle events to the user's relay Worker. User-level settings never
# sync to cloud sandboxes, so this must live in the repo — but it is inert
# everywhere except a cloud sandbox, and carries no secrets: the relay URL
# and token come from env vars set in the Claude Code environment config.
#
# Must always exit 0 and never block — it runs inline in Claude Code.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ -n "${STATUS_LIGHT_RELAY_URL:-}" ] || exit 0
[ -n "${STATUS_LIGHT_RELAY_TOKEN:-}" ] || exit 0

PAYLOAD="$(cat 2>/dev/null || true)"

printf '%s' "$PAYLOAD" | curl -s -m 2 -X POST "$STATUS_LIGHT_RELAY_URL/hook" \
    -H "Authorization: Bearer $STATUS_LIGHT_RELAY_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @- >/dev/null 2>&1 &

exit 0
