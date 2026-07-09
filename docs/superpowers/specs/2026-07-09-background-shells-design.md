# Surface running background shells

2026-07-09 · approved by Luke

## Problem

A session can finish its turn (light goes green) while a Bash command it
launched with `run_in_background` keeps running — a training job, a server, a
long data build. Shells fire no hook events (verified empirically), so the
light claims "awaiting next task" while real Claude-spawned work is running,
and nothing says what that work is.

## Decisions

- A session that is `idle` but has running shells is upgraded to **working**
  at the source (StateStore), so the row dot, the aggregate menu-bar light,
  and the dancing mascot all go yellow through existing paths. `attention`
  is never masked — blocked-on-you always wins.
- The command is shown **inline in the row**: one shell →
  `mlb-props · sh: uv run python feature_engineering/batch…` (~40 chars),
  several → `· 2 sh: <first command>…`. Full commands go in the tooltip.

## Detection

`ShellScanner`, app-side only (no hook changes), runs during the 1s poll:

1. One `sysctl KERN_PROC_ALL` snapshot → (pid, ppid) pairs.
2. Direct children of each session's recorded pid.
3. Child argv via `sysctl KERN_PROCARGS2`; keep those containing
   `.claude/shell-snapshots/snapshot-` — the harness's wrapper around every
   Bash tool command, so user processes can't match. Orphaned strays
   (reparented to pid 1) are naturally excluded.
4. The real command is extracted from the wrapper's `eval '…'` argument
   (unescaping `'\''`), falling back to the raw `-c` string tail if the
   wrapper shape ever changes.

Foreground commands can't false-positive the upgrade: while one runs, the
session is already `working`.

## Model

`SessionState` gains `shells: [String]` (extracted commands), a
`shellsSuffix` row segment beside the existing `agentsSuffix`, and a shared
`tooltip` (cwd, terminal, background note, full shell commands) so the menu
and panel stop building their own. `StateStore` takes an injectable
shells-lookup (default: `ShellScanner`) for testability.

## Testing

- Pure tests for `eval` extraction (quotes, escaping, fallback).
- Integration: spawn a real child carrying the signature in its argv; the
  scanner finds it under the test's own pid and extracts its command.
- StateStore with an injected lookup: idle+shells → working, attention
  unchanged, no-pid sessions never scanned.
- Label tests for `shellsSuffix` singular/plural/truncation.
