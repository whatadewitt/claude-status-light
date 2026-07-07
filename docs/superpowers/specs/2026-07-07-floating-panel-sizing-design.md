# Stable floating panel sizing

**Date:** 2026-07-07
**Status:** Approved

## Problem

The floating panel resizes on every state update because the title text
("Claude Code — Running…" vs "— Awaiting next task" vs "— Waiting for
input") changes length, making the panel visibly bounce between widths.
Separately, the title runs flush against the panel's right edge — the
trailing edge inset is missing from the computed size.

## Fix

All in `FloatingPanelController.update`:

- **Width:** compute a stable minimum width as the widest of the four
  possible titles measured with the title font (bold 12 pt), plus the icon
  (16), icon spacing (6), and both edge insets (12 + 12). Panel width is
  `max(stableTitleWidth, widest session row + insets)` — state flips never
  change width; only the session list can (e.g. a long project name).
- **Height:** unchanged — fits content, grows/shrinks with the session
  list.
- **Right padding:** fixed as a side effect. Width is computed explicitly
  with both insets included instead of trusting `container.fittingSize`,
  which drops the trailing inset. Panel size is set with
  `setContentSize(NSSize(width: computedWidth, height:
  container.fittingSize.height))`.
- **Repositioning:** no changes to `reposition()`; with constant width,
  corner-locked panels also stop sliding horizontally on state changes.

## Verification

Rebuild, reinstall, flip through states with live sessions: constant width
across all four states, visible right padding, title never truncates.
