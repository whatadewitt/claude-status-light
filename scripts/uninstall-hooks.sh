#!/bin/bash
#
# uninstall-hooks.sh — remove the status light hooks from settings.json.
#
# Removes only the entries this tool installed (identified by claude-status.sh)
# and leaves all your other hooks intact. Also removes the installed script and
# any leftover session state.
#
# Usage:
#   scripts/uninstall-hooks.sh [path/to/settings.json]
#
set -euo pipefail

settings_file="${1:-$HOME/.claude/settings.json}"

if [ -f "$settings_file" ] && command -v python3 >/dev/null 2>&1; then
  echo "==> Removing status-light hooks from $settings_file"
  python3 - "$settings_file" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
hooks = data.get("hooks", {})
marker = "claude-status.sh"
for event in list(hooks.keys()):
    groups = hooks.get(event, [])
    if not isinstance(groups, list):
        continue
    kept = []
    for group in groups:
        if not isinstance(group, dict):
            kept.append(group); continue
        inner = [h for h in group.get("hooks", [])
                 if not (isinstance(h, dict) and marker in str(h.get("command", "")))]
        if inner:
            group = dict(group); group["hooks"] = inner; kept.append(group)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if not hooks:
    data.pop("hooks", None)
with open(path, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
print("   done")
PY
else
  echo "Nothing to do (no settings file or no python3)."
fi

echo "==> Removing installed hook script and session state"
rm -rf "$HOME/.claude/status-light/bin" "$HOME/.claude/status-light/sessions"

echo "Uninstalled. Quit the ClaudeStatusLight app from the menu bar to finish."
