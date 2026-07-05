#!/usr/bin/env bash
#
# install-hooks.sh — wire the status light into Claude Code.
#
# This:
#   1. Copies bin/claude-status to ~/.claude/status-light/bin (on your PATH-free
#      absolute path used by the hooks).
#   2. Merges the hook configuration into ~/.claude/settings.json, keeping any
#      hooks you already have. A timestamped backup is written first.
#
# Safe to re-run; it replaces only the status-light hook entries.

set -euo pipefail
cd "$(dirname "$0")"

CLAUDE_DIR="${HOME}/.claude"
INSTALL_BIN_DIR="${CLAUDE_DIR}/status-light/bin"
SETTINGS="${CLAUDE_DIR}/settings.json"
SNIPPET="hooks/settings.snippet.json"

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: python3 is required to merge settings.json safely." >&2
  exit 1
fi

echo "Installing helper to ${INSTALL_BIN_DIR}/claude-status"
mkdir -p "${INSTALL_BIN_DIR}"
install -m 0755 bin/claude-status "${INSTALL_BIN_DIR}/claude-status"

# Render the snippet with the real absolute bin path.
RENDERED_SNIPPET="$(mktemp)"
trap 'rm -f "${RENDERED_SNIPPET}"' EXIT
sed "s|__BIN__|${INSTALL_BIN_DIR}|g" "${SNIPPET}" > "${RENDERED_SNIPPET}"

mkdir -p "${CLAUDE_DIR}"
if [ ! -f "${SETTINGS}" ]; then
  echo '{}' > "${SETTINGS}"
fi

BACKUP="${SETTINGS}.bak.$(date +%Y%m%d%H%M%S)"
cp "${SETTINGS}" "${BACKUP}"
echo "Backed up existing settings to ${BACKUP}"

python3 - "${SETTINGS}" "${RENDERED_SNIPPET}" <<'PY'
import json, sys

settings_path, snippet_path = sys.argv[1], sys.argv[2]

with open(settings_path) as f:
    try:
        settings = json.load(f)
    except json.JSONDecodeError:
        settings = {}
with open(snippet_path) as f:
    snippet = json.load(f)

settings.setdefault("hooks", {})

# For each event, drop any prior status-light entries (identified by the
# claude-status command) so re-running doesn't stack duplicates, then append
# ours. Other hooks the user configured are left untouched.
def is_status_light(group):
    for h in group.get("hooks", []):
        if "claude-status" in h.get("command", ""):
            return True
    return False

for event, groups in snippet["hooks"].items():
    existing = settings["hooks"].get(event, [])
    existing = [g for g in existing if not is_status_light(g)]
    settings["hooks"][event] = existing + groups

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(f"Merged status-light hooks into {settings_path}")
PY

echo
echo "Done. Restart any running Claude Code sessions so the new hooks load."
echo "Then build and launch the app:  ./build.sh && open build/ClaudeStatusLight.app"
