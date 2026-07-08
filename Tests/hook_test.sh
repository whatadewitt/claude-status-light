#!/bin/bash
# Tests for hooks/status-hook.sh — runs on macOS and Linux (CI).
#
# The hook must record the PID of its nearest non-shell ancestor (the Claude
# Code process that spawned it), so the app can drop sessions whose process
# has exited. A python3 wrapper stands in for Claude Code here: the hook's
# recorded pid must equal the python process's pid, even when extra shells
# sit in between.

set -euo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/status-hook.sh"
export HOME="$(mktemp -d)"
SESSIONS="$HOME/.claude/status-light/sessions"

echo "--- hook records parent pid (direct child)"
python3 - "$HOOK" <<'PY'
import json, os, subprocess, sys
payload = json.dumps({"session_id": "test-direct", "cwd": "/tmp/proj"})
subprocess.run(["bash", sys.argv[1], "working"], input=payload.encode(), check=True)
data = json.load(open(os.path.expanduser("~/.claude/status-light/sessions/test-direct.json")))
assert data["state"] == "working", data
assert data.get("pid") == os.getpid(), f"pid: expected {os.getpid()}, got {data.get('pid')!r}"
assert "tty" in data, data
print("ok")
PY

echo "--- hook skips intermediate shells when finding its owner"
python3 - "$HOOK" <<'PY'
import json, os, subprocess, sys
payload = json.dumps({"session_id": "test-nested", "cwd": "/tmp/proj"})
subprocess.run(["sh", "-c", f'exec < /dev/stdin; bash "$1" idle', "sh", sys.argv[1]],
               input=payload.encode(), check=True)
data = json.load(open(os.path.expanduser("~/.claude/status-light/sessions/test-nested.json")))
assert data.get("pid") == os.getpid(), f"pid: expected {os.getpid()}, got {data.get('pid')!r}"
print("ok")
PY

echo "--- end removes the session file"
printf '{"session_id":"test-direct"}' | bash "$HOOK" end
[ ! -e "$SESSIONS/test-direct.json" ] || { echo "FAIL: end did not remove file" >&2; exit 1; }
echo "ok"

echo "--- state file is valid JSON with expected fields"
printf '{"session_id":"test-fields","cwd":"/tmp/proj"}' | bash "$HOOK" attention
python3 - <<'PY'
import json, os
data = json.load(open(os.path.expanduser("~/.claude/status-light/sessions/test-fields.json")))
for key in ("state", "session_id", "cwd", "term_program", "tty", "pid", "updated_at"):
    assert key in data, f"missing {key}: {data}"
assert data["state"] == "attention", data
assert data["cwd"] == "/tmp/proj", data
assert isinstance(data["pid"], int), data
assert isinstance(data["updated_at"], int), data
print("ok")
PY

echo "--- attention downgrades to idle for the 'waiting for your input' reminder"
printf '{"session_id":"test-idle-note","message":"Claude is waiting for your input"}' | bash "$HOOK" attention
printf '{"session_id":"test-perm-note","message":"Claude needs your permission to use Bash"}' | bash "$HOOK" attention
python3 - <<'PY'
import json, os
base = os.path.expanduser("~/.claude/status-light/sessions/")
idle = json.load(open(base + "test-idle-note.json"))
perm = json.load(open(base + "test-perm-note.json"))
assert idle["state"] == "idle", idle
assert perm["state"] == "attention", perm
print("ok")
PY

echo "--- AskUserQuestion upgrades working to attention (blocked on an answer)"
printf '{"session_id":"test-ask","tool_name":"AskUserQuestion","tool_input":{}}' | bash "$HOOK" working
printf '{"session_id":"test-bash","tool_name":"Bash","tool_input":{"command":"ls"}}' | bash "$HOOK" working
python3 - <<'PY'
import json, os
base = os.path.expanduser("~/.claude/status-light/sessions/")
ask = json.load(open(base + "test-ask.json"))
bash = json.load(open(base + "test-bash.json"))
assert ask["state"] == "attention", ask
assert bash["state"] == "working", bash
print("ok")
PY

echo "--- agent-start/agent-stop maintain per-session subagent markers"
printf '{"session_id":"test-agents","cwd":"/tmp/proj"}' | bash "$HOOK" working
printf '{"session_id":"test-agents"}' | bash "$HOOK" agent-start
printf '{"session_id":"test-agents"}' | bash "$HOOK" agent-start
[ "$(ls "$SESSIONS/test-agents.agents" | wc -l | tr -d ' ')" = "2" ] \
    || { echo "FAIL: expected 2 markers after two starts" >&2; exit 1; }
printf '{"session_id":"test-agents"}' | bash "$HOOK" agent-stop
[ "$(ls "$SESSIONS/test-agents.agents" | wc -l | tr -d ' ')" = "1" ] \
    || { echo "FAIL: expected 1 marker after a stop" >&2; exit 1; }
# extra stops on an empty/absent dir must be harmless
printf '{"session_id":"test-agents"}' | bash "$HOOK" agent-stop
printf '{"session_id":"test-agents"}' | bash "$HOOK" agent-stop
[ "$(ls "$SESSIONS/test-agents.agents" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
    || { echo "FAIL: expected 0 markers after draining" >&2; exit 1; }
# agent events never touch the session state file
python3 - <<'PY'
import json, os
data = json.load(open(os.path.expanduser("~/.claude/status-light/sessions/test-agents.json")))
assert data["state"] == "working", data
print("ok")
PY

echo "--- agent-start without a session file creates nothing"
printf '{"session_id":"test-ghost"}' | bash "$HOOK" agent-start
[ ! -e "$SESSIONS/test-ghost.json" ] && [ ! -e "$SESSIONS/test-ghost.agents" ] \
    || { echo "FAIL: ghost session artifacts created" >&2; exit 1; }
echo "ok"

echo "--- SessionStart wipes leftover markers; end removes them with the session"
printf '{"session_id":"test-agents"}' | bash "$HOOK" agent-start
printf '{"session_id":"test-agents","hook_event_name":"SessionStart"}' | bash "$HOOK" idle
[ ! -e "$SESSIONS/test-agents.agents" ] \
    || { echo "FAIL: SessionStart did not wipe markers" >&2; exit 1; }
printf '{"session_id":"test-agents"}' | bash "$HOOK" agent-start
printf '{"session_id":"test-agents"}' | bash "$HOOK" end
[ ! -e "$SESSIONS/test-agents.json" ] && [ ! -e "$SESSIONS/test-agents.agents" ] \
    || { echo "FAIL: end left artifacts behind" >&2; exit 1; }
echo "ok"

echo "All hook tests passed."
