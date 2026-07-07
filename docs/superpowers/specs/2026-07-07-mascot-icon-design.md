# Pixel-mascot status icon

**Date:** 2026-07-07
**Status:** Approved

## Goal

Replace the radial "spark" burst status glyph with the Claude Code pixel
mascot, tinted to the existing state colors, everywhere the app draws its
icon.

## Mascot shape

Transcribed from a screenshot of the Claude Code app mascot. Measured
proportions map onto a 13-column × 11-row cell grid:

```
.XXXXXXXXXXX.
.XXXXXXXXXXX.
.XX.XXXXX.XX.   <- tall slit eyes (transparent)
.XX.XXXXX.XX.
XXXXXXXXXXXXX   <- full-width "arms" band
XXXXXXXXXXXXX
XXXXXXXXXXXXX
.XXXXXXXXXXX.
.XXXXXXXXXXX.
..X.X...X.X..   <- four legs, wider middle gap
..X.X...X.X..
```

No antennae — the source artwork is a flat-top body.

## Rendering

- `IconRenderer` gains a hardcoded pixel grid (array of strings, `X` =
  filled) and a `drawMascot(color:in:)` that fills each cell as a square,
  replacing `drawBurst` as the default glyph.
- Antialiasing is disabled while filling cells so edges stay crisp at menu
  bar size; cell boundaries are snapped so adjacent cells share edges with
  no hairline cracks.
- The grid is letterboxed (centered) in the square icon rect.

## Call sites (unchanged)

Menu bar (18 px), floating window (16 px), and dock (128 px with its
rounded dark tile) all go through `IconRenderer.icon(for:side:)` and pick
up the mascot automatically, tinted gray / yellow / green / red per
`LightState.color`.

## Finder app icon

The neutral `.icns` glyph (`drawAppIcon`) becomes the mascot in Claude
terracotta (`#D97757`) on the existing dark rounded tile. State-independent
as before.

## Custom override (unchanged)

`~/.claude/status-light/icon.png` still wins when present, drawn full-color
with the corner state badge.

## Verification

Build; render sample PNGs at 16 / 18 / 128 px in all four states for visual
review; regenerate the app iconset. Existing tests (`StateStoreTests`,
`hook_test.sh`) unaffected — the change is purely visual rendering.
