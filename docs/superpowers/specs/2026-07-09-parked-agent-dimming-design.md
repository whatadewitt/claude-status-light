# Dim parked background agents

2026-07-09 · approved by Luke

## Problem

Claude Code parks finished background agents instead of exiting them: the
process stays alive "awaiting next task", so its row lingers green
indefinitely. The row is truthful (live process) but visually equal in weight
to sessions that matter right now.

## Definition

A session is **parked** when it is headless (background), `idle`, and quiet
for **2+ minutes** (`updatedAt` age — hook events reset the clock). Working
agents fire events constantly; an agent kept busy by its own background shell
is upgraded to `working`, so neither ever dims. Interactive terminals never
dim — idling at a prompt is normal, not parked.

`isParked` is a computed property on `SessionState`, a pure function of
fields it already carries.

## Appearance

Row text drops to secondary (gray) color — attributed title in the menu,
`contentTintColor` in the floating panel. The green dot stays green: the
state is still truthfully "idle, process alive"; dimming only removes visual
weight. The tooltip gains `parked — idle Nm, process alive`. Aggregate light,
sorting, and focus behavior are untouched.

## Testing

`isParked` truth table (fresh bg idle → no; 2min+ bg idle → yes; old
interactive idle → no; old bg working → no) and the tooltip line. The gray
rendering is AppKit glue over the tested predicate.
