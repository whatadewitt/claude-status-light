# Notification classification + dancing mascot

**Date:** 2026-07-07
**Status:** Approved

## Problem 1: idle reminder turns the light red

The desired mapping is already configured (green = ready for next prompt,
yellow = working, red = stopped waiting for input), but Claude Code's
`Notification` hook event fires for two different things and both turn the
light red:

- permission prompts ("Claude needs your permission to use X") — red is
  correct;
- the idle reminder fired after ~60 s without input ("Claude is waiting
  for your input") — this means "ready for your next prompt" and should be
  green.

### Fix

In `hooks/status-hook.sh`: when invoked with `attention`, check the
payload's `message` field; if it contains "waiting for your input"
(case-insensitive), record `idle` instead. Everything else stays
`attention`. No settings.json or color changes.

## Problem 2: dancing mascot while working

The mascot should animate ("dance") while Claude is working, in all three
spots: menu bar, floating window, and dock icon.

### Design

- `IconRenderer.mascotGrid` becomes `mascotFrames: [[String]]`. Frame 0 is
  the existing rest pose; two more frames form a scuttle/bounce (legs
  shuffle a cell, body bobs a row). `icon(for:side:background:frame:)`
  gains a `frame` parameter defaulting to 0 so existing call sites are
  untouched.
- An animator in `AppDelegate` (which already coordinates all three
  surfaces) runs a ~0.5 s timer only while state is `.working`, cycling
  the frame index and pushing re-rendered icons to the menu bar button,
  the floating panel's icon view, and the dock icon (dock only when
  enabled in Settings). Any other state stops the timer and shows the
  rest pose, so green/red are always still.
- `StatusBarController` and `FloatingPanelController` expose a lightweight
  way to update just the icon image for the current state without
  rebuilding menus/panels.

## Verification

- Hook: pipe synthetic Notification payloads (permission message vs idle
  reminder) through the script and assert the recorded state.
- Frames: render a preview strip of the three frames in each state for
  visual review before finalizing choreography.
- Live: rebuild, reinstall, run a session and watch the mascot dance while
  working and freeze when done/blocked.
