#!/bin/bash
#
# install-hooks.sh — wire Claude Code hooks to the status light.
#
# Installs claude-status.sh to a stable location and merges the hook
# configuration into your Claude Code settings.json (idempotently — safe to
# re-run; it replaces its own entries and leaves your other hooks untouched).
#
# Usage:
#   scripts/install-hooks.sh [path/to/settings.json]
#
# Default settings file: ~/.claude/settings.json (applies to all projects).
#
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
settings_file="${1:-$HOME/.claude/settings.json}"

install_dir="$HOME/.claude/status-light/bin"
installed_hook="$install_dir/claude-status.sh"

echo "==> Installing hook script to $installed_hook"
mkdir -p "$install_dir"
cp "$repo_root/hooks/claude-status.sh" "$installed_hook"
chmod +x "$installed_hook"

mkdir -p "$(dirname "$settings_file")"
[ -f "$settings_file" ] || echo '{}' > "$settings_file"

echo "==> Merging hooks into $settings_file"

# The event -> status mapping. Each hook runs: claude-status.sh <status>
#   UserPromptSubmit / Pre+PostToolUse -> working   (yellow)
#   Notification                       -> waiting   (red — needs your input)
#   Stop / SessionStart                -> idle      (green)
#   SessionEnd                         -> end        (remove the session's file)

merge_with_python() {
  "$1" - "$settings_file" "$installed_hook" <<'PY'
import json, sys

settings_path, hook_path = sys.argv[1], sys.argv[2]

mapping = {
    "UserPromptSubmit": "working",
    "PreToolUse":       "working",
    "PostToolUse":      "working",
    "Notification":     "waiting",
    "Stop":             "idle",
    "SessionStart":     "idle",
    "SessionEnd":       "end",
}

with open(settings_path) as f:
    try:
        data = json.load(f)
    except json.JSONDecodeError:
        raise SystemExit(f"error: {settings_path} is not valid JSON; fix it and re-run")

if not isinstance(data, dict):
    raise SystemExit(f"error: {settings_path} does not contain a JSON object")

hooks = data.setdefault("hooks", {})
marker = "claude-status.sh"  # identifies entries we own

for event, status in mapping.items():
    command = f'"{hook_path}" {status}'
    groups = hooks.get(event, [])
    if not isinstance(groups, list):
        groups = []
    # Drop any command entries we previously installed.
    cleaned = []
    for group in groups:
        if not isinstance(group, dict):
            cleaned.append(group)
            continue
        inner = [h for h in group.get("hooks", [])
                 if not (isinstance(h, dict) and marker in str(h.get("command", "")))]
        if inner:
            group = dict(group)
            group["hooks"] = inner
            cleaned.append(group)
        elif not group.get("hooks"):
            # group had no hooks to begin with; keep as-is
            cleaned.append(group)
    # Append our fresh entry (empty matcher = all tools / all events).
    cleaned.append({"matcher": "", "hooks": [{"type": "command", "command": command}]})
    hooks[event] = cleaned

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("   merged", len(mapping), "hook events")
PY
}

if command -v python3 >/dev/null 2>&1; then
  merge_with_python python3
elif command -v python >/dev/null 2>&1; then
  merge_with_python python
else
  echo "error: python3 not found — cannot safely merge JSON." >&2
  echo "See hooks/settings.snippet.json and merge it into $settings_file by hand." >&2
  exit 1
fi

echo ""
echo "Hooks installed. New Claude Code sessions will report to the status light."
echo "Restart any running 'claude' sessions to pick up the new hooks."
