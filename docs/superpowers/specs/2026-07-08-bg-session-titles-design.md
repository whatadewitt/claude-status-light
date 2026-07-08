# Background session titles

2026-07-08 · approved by Luke

## Problem

Claude Code's background-task daemon runs agents as separate headless sessions.
The light renders them as `mlb-props (bg)` — real rows, but "(bg)" says nothing
about what the agent is doing. Each agent's transcript starts with its
AI-generated task title (`agent-name` / `ai-title` lines), so a real
description is available on disk.

## Decisions

- Titles appear on **background sessions only**; interactive rows stay plain
  project names.
- Row format is **project first**: `mlb-props · Improve system win rate from 59%`
  (title truncated to ~48 chars). A titled row drops the now-redundant `(bg)`.
  Untitled background sessions (e.g. pre-warmed spares with no transcript)
  keep `(bg)`. The `· N agents` suffix still appends after.

## Data flow

1. **Hook** copies the payload's `transcript_path` (authoritative, present on
   every event) into the session JSON verbatim. No parsing in bash — titles can
   contain quotes/unicode, and the hook must stay fast.
2. **App** (`StateStore` poll) reads the first 64KB of the transcript,
   JSON-decodes only lines containing `agent-name` / `ai-title`, and takes the
   last `agent-name` match, falling back to the last `ai-title`. Missing or
   unreadable transcript → no title.
3. **Cache** per session keyed on transcript file size: unchanged size → no
   re-read. Steady-state cost is one `stat` per background session per tick.

Rejected alternatives: parsing the title in the hook (fragile bash JSON), and
deriving the transcript path from the cwd (the `~/.claude/projects/` munging
rule is undocumented).

## Display

`SessionState` gains `title: String?` and one shared label helper used by the
menu and the floating panel, so the two surfaces cannot drift.

## Testing

- Hook test: `transcript_path` lands in the session file.
- Swift tests: title extraction from a fixture transcript (agent-name beats
  ai-title, last occurrence wins, no transcript → nil), truncation, and label
  composition for titled/untitled/interactive sessions.
