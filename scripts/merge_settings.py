#!/usr/bin/env python3
"""Add or remove the status-light hooks in ~/.claude/settings.json.

Usage:
    merge_settings.py add    /abs/path/to/status-hook.sh
    merge_settings.py remove /abs/path/to/status-hook.sh

Idempotent: running "add" twice will not duplicate entries. A timestamped
backup of settings.json is written before any change.
"""
import json
import os
import shutil
import sys
import time

# Claude Code hook event -> light state reported by the hook.
EVENT_STATES = {
    "SessionStart": "idle",
    "UserPromptSubmit": "working",
    "PreToolUse": "working",
    "PostToolUse": "working",
    "Notification": "attention",
    "Stop": "idle",
    "SessionEnd": "end",
}

# Tool-scoped events take a matcher; the rest do not.
MATCHER_EVENTS = {"PreToolUse", "PostToolUse"}

SETTINGS_PATH = os.path.expanduser("~/.claude/settings.json")


def command_for(hook_path, state):
    return f'"{hook_path}" {state}'


def load_settings():
    if not os.path.exists(SETTINGS_PATH):
        os.makedirs(os.path.dirname(SETTINGS_PATH), exist_ok=True)
        return {}
    with open(SETTINGS_PATH) as f:
        try:
            return json.load(f)
        except json.JSONDecodeError as exc:
            sys.exit(f"ERROR: {SETTINGS_PATH} is not valid JSON ({exc}). Aborting.")


def save_settings(settings):
    if os.path.exists(SETTINGS_PATH):
        shutil.copy(SETTINGS_PATH, f"{SETTINGS_PATH}.bak.{int(time.time())}")
    with open(SETTINGS_PATH, "w") as f:
        json.dump(settings, f, indent=2)
        f.write("\n")


def add(hook_path):
    settings = load_settings()
    hooks = settings.setdefault("hooks", {})

    for event, state in EVENT_STATES.items():
        cmd = command_for(hook_path, state)
        groups = hooks.setdefault(event, [])

        already = any(
            h.get("command", "").strip() == cmd
            for group in groups
            for h in group.get("hooks", [])
        )
        if already:
            continue

        group = {"hooks": [{"type": "command", "command": cmd}]}
        if event in MATCHER_EVENTS:
            group = {"matcher": "*", **group}
        groups.append(group)

    save_settings(settings)
    print(f"Added status-light hooks to {SETTINGS_PATH}")


def remove(hook_path):
    settings = load_settings()
    hooks = settings.get("hooks", {})
    changed = False

    for event in list(hooks.keys()):
        groups = hooks.get(event, [])
        new_groups = []
        for group in groups:
            kept = [
                h for h in group.get("hooks", [])
                if hook_path not in h.get("command", "")
            ]
            if len(kept) != len(group.get("hooks", [])):
                changed = True
            if kept:
                new_group = dict(group)
                new_group["hooks"] = kept
                new_groups.append(new_group)
            elif not group.get("hooks"):
                new_groups.append(group)
        if new_groups:
            hooks[event] = new_groups
        else:
            del hooks[event]
            changed = True

    if not hooks:
        settings.pop("hooks", None)

    if changed:
        save_settings(settings)
        print(f"Removed status-light hooks from {SETTINGS_PATH}")
    else:
        print("No status-light hooks found; nothing to remove.")


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("add", "remove"):
        sys.exit(__doc__)
    action, hook_path = sys.argv[1], sys.argv[2]
    if action == "add":
        add(hook_path)
    else:
        remove(hook_path)


if __name__ == "__main__":
    main()
