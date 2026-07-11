#!/bin/bash
# Tests for hooks/status-relay.sh — the cloud-side relay hook.
#
# The script must be inert outside cloud sandboxes (no CLAUDE_CODE_REMOTE),
# inert without relay env vars, and otherwise POST the raw hook payload to
# $STATUS_LIGHT_RELAY_URL/hook with the bearer token — in the background,
# always exiting 0 immediately.
set -euo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/status-relay.sh"
TMP="$(mktemp -d)"
export CURL_LOG="$TMP/curl.log"

cat > "$TMP/curl" <<'SH'
#!/bin/bash
{ echo "ARGS: $*"; cat; echo; } >> "${CURL_LOG:?}"
SH
chmod +x "$TMP/curl"
export PATH="$TMP:$PATH"

echo "--- inert without CLAUDE_CODE_REMOTE"
printf '{"session_id":"s1"}' | bash "$HOOK"
sleep 0.3
[ ! -e "$CURL_LOG" ] || { echo "FAIL: curl ran locally" >&2; exit 1; }

echo "--- inert without relay env vars"
printf '{"session_id":"s1"}' | CLAUDE_CODE_REMOTE=true bash "$HOOK"
sleep 0.3
[ ! -e "$CURL_LOG" ] || { echo "FAIL: curl ran without config" >&2; exit 1; }

echo "--- posts the payload when remote env is present"
export CLAUDE_CODE_REMOTE=true
export STATUS_LIGHT_RELAY_URL="https://relay.example"
export STATUS_LIGHT_RELAY_TOKEN="tok"
printf '{"session_id":"s1","hook_event_name":"Stop"}' | bash "$HOOK"
sleep 0.5  # the curl is backgrounded
grep -q 'https://relay.example/hook' "$CURL_LOG" || { echo "FAIL: missing url" >&2; exit 1; }
grep -q 'Bearer tok' "$CURL_LOG" || { echo "FAIL: missing token" >&2; exit 1; }
grep -q '"hook_event_name":"Stop"' "$CURL_LOG" || { echo "FAIL: missing payload" >&2; exit 1; }

echo "all ok"
