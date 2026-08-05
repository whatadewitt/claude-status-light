# Permission-Mode Indicator Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each session's Claude Code permission mode (plan, auto-edit, bypass, …) on the floating panel and menu rows, captured from the `permission_mode` field in hook payloads.

**Architecture:** The shell hook extracts `permission_mode` from hook payloads into the per-session state file (sticky across events that lack it). `StateStore` parses it into `SessionState.permissionMode`; a new `modeSuffix` descriptor renders it on both UI surfaces. `WireSession` carries it as an optional field so paired Macs see it too.

**Tech Stack:** Bash (hook), Swift + swift-testing (`@Test` / `#expect`), plain JSON state files. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-08-05-permission-mode-design.md`

## Global Constraints

- The hook (`hooks/status-hook.sh`) must always `exit 0`, never block, and must not require `jq` — use the existing `extract`/`extract_from` helpers.
- Wire/state-file keys are snake_case: the new key is exactly `permission_mode`.
- `WireSession.permissionMode` must be optional so JSON without the key (old publishers, stored relay snapshots) still decodes — no relay redeploy.
- Display rule: suffix only for non-default modes; `default` (and absent) show nothing on the row. Tooltip shows the mode whenever known, including `default`. Unknown values render raw, never hidden.
- Swift tests run via `./scripts/test.sh` (wraps `swift test` with CommandLineTools framework paths). Hook tests run via `bash Tests/hook_test.sh`.
- Commit messages: end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Hook captures `permission_mode` (sticky)

**Files:**
- Modify: `hooks/status-hook.sh` (extraction near line 145, printf near line 153, header comment lines 9–13)
- Test: `Tests/hook_test.sh`

**Interfaces:**
- Produces: per-session state file gains `"permission_mode":"<value>"` — always present, empty string when no event has ever carried it. Task 3 parses this key.

Background: Claude Code sends `permission_mode` (`default` | `plan` | `acceptEdits` | `auto` | `dontAsk` | `bypassPermissions`) on `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, and `Stop` — but NOT on `SessionStart` or `Notification`. Those two must not blank a previously recorded mode, hence the sticky read-back, mirroring the existing terminal-identity stickiness at `hooks/status-hook.sh:134-145`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/hook_test.sh` (before the final section of the file; follow the existing `echo "--- …"` + python3 heredoc style):

```bash
echo "--- permission_mode lands in the state file and stays sticky"
printf '{"session_id":"test-mode","cwd":"/tmp/proj","permission_mode":"plan"}' | bash "$HOOK" working
# Notification carries no permission_mode — must keep the recorded one.
printf '{"session_id":"test-mode","message":"Claude needs your permission to use Bash"}' | bash "$HOOK" attention
python3 - <<'PY'
import json, os
data = json.load(open(os.path.expanduser("~/.claude/status-light/sessions/test-mode.json")))
assert data["permission_mode"] == "plan", data
print("ok")
PY

echo "--- a later event with a different mode overwrites it"
printf '{"session_id":"test-mode","permission_mode":"acceptEdits"}' | bash "$HOOK" working
python3 - <<'PY'
import json, os
data = json.load(open(os.path.expanduser("~/.claude/status-light/sessions/test-mode.json")))
assert data["permission_mode"] == "acceptEdits", data
print("ok")
PY

echo "--- sessions that never saw a mode record an empty one"
printf '{"session_id":"test-no-mode","cwd":"/tmp/proj"}' | bash "$HOOK" working
python3 - <<'PY'
import json, os
data = json.load(open(os.path.expanduser("~/.claude/status-light/sessions/test-no-mode.json")))
assert data.get("permission_mode") == "", data
print("ok")
PY
```

Also extend the existing `--- state file is valid JSON with expected fields` test: add `"permission_mode"` to its `for key in (…)` tuple.

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash Tests/hook_test.sh`
Expected: FAIL at the new `permission_mode lands in the state file` assertion (`KeyError`/assert on missing key).

- [ ] **Step 3: Implement in the hook**

In `hooks/status-hook.sh`, immediately after the sticky terminal-identity block (after line 145, before the `if [ "$STATE" = "end" ]` block), add:

```bash
# Most events carry the live permission mode (default/plan/acceptEdits/…);
# SessionStart and Notification don't. Keep the recorded mode so those
# events can't blank it — same sticky pattern as terminal identity above.
PERMISSION_MODE="$(extract permission_mode)"
if [ -z "$PERMISSION_MODE" ] && [ -f "$FILE" ]; then
    PERMISSION_MODE="$(extract_from "$(cat "$FILE" 2>/dev/null || true)" permission_mode)"
fi
```

Change the printf (line 153) to include the field before `updated_at`:

```bash
    printf '{"state":"%s","session_id":"%s","cwd":"%s","term_program":"%s","tty":"%s","pid":%d,"transcript_path":"%s","permission_mode":"%s","updated_at":%s}\n' \
        "$STATE" \
        "$(esc "$SESSION_ID")" \
        "$(esc "$CWD")" \
        "$(esc "$TERM_PROG")" \
        "$(esc "$TTY_PATH")" \
        "${CLAUDE_PID:-0}" \
        "$(esc "$TRANSCRIPT")" \
        "$(esc "$PERMISSION_MODE")" \
        "$(date +%s)" \
        > "$FILE" 2>/dev/null
```

Update the header comment (lines 9–13) to mention the mode, e.g. change "extracts the session_id and cwd" to "extracts the session_id, cwd, and permission mode".

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash Tests/hook_test.sh`
Expected: all sections print `ok`, including the three new ones.

- [ ] **Step 5: Commit**

```bash
git add hooks/status-hook.sh Tests/hook_test.sh
git commit -m "Capture permission_mode in the session state file

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: `SessionState.permissionMode`, `modeSuffix`, tooltip line

**Files:**
- Modify: `Sources/ClaudeStatusLight/Model.swift` (SessionState struct, ~lines 39–136)
- Test: `Tests/ClaudeStatusLightTests/SessionLabelTests.swift`

**Interfaces:**
- Produces: `SessionState.permissionMode: String?` (defaulted stored property, so existing constructors compile unchanged; label order in the memberwise init is `…, shells:, origin:, backgroundOverride:, permissionMode:`). `SessionState.modeSuffix: String` — `""` for nil/empty/`default`, else `" · <label>"`. Tasks 3–5 consume both.

- [ ] **Step 1: Write the failing tests**

In `Tests/ClaudeStatusLightTests/SessionLabelTests.swift`, extend the private `session(…)` helper with a mode parameter:

```swift
    private func session(
        state: LightState = .idle,
        tty: String = "",
        pid: Int? = 4242,
        age: TimeInterval = 0,
        agents: Int = 0,
        title: String? = nil,
        shells: [String] = [],
        mode: String? = nil
    ) -> SessionState {
        SessionState(
            sessionID: "s", state: state, cwd: "/tmp/mlb-props",
            termProgram: "unknown", tty: tty, pid: pid,
            updatedAt: Date().addingTimeInterval(-age),
            agents: agents, title: title, shells: shells,
            permissionMode: mode
        )
    }
```

Add tests (after `agentsSuffixPluralizes`):

```swift
    @Test func modeSuffixShowsNonDefaultModes() {
        #expect(session().modeSuffix == "")
        #expect(session(mode: "default").modeSuffix == "")
        #expect(session(mode: "plan").modeSuffix == " · plan")
        #expect(session(mode: "acceptEdits").modeSuffix == " · auto-edit")
        #expect(session(mode: "auto").modeSuffix == " · auto")
        #expect(session(mode: "dontAsk").modeSuffix == " · don't-ask")
        #expect(session(mode: "bypassPermissions").modeSuffix == " · bypass")
    }

    @Test func unknownModesShowRawRatherThanHidden() {
        #expect(session(mode: "yolo").modeSuffix == " · yolo")
    }

    @Test func tooltipShowsModeIncludingDefault() {
        #expect(session(mode: "default").tooltip.contains("mode: default"))
        #expect(session(mode: "plan").tooltip.contains("mode: plan"))
        #expect(!session().tooltip.contains("mode:"))
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter SessionLabelTests`
Expected: FAIL to compile — `extra argument 'permissionMode' in call` / `value of type 'SessionState' has no member 'modeSuffix'`.

- [ ] **Step 3: Implement in Model.swift**

Add a stored property to `SessionState` directly after `var backgroundOverride: Bool? = nil` (Model.swift:62):

```swift
    /// Claude Code permission mode from hook payloads ("default", "plan",
    /// "acceptEdits", …). nil until an event carrying it has fired.
    var permissionMode: String? = nil
```

Add the suffix next to `agentsSuffix` (after Model.swift:105):

```swift
    /// " · plan" (etc.) for non-default permission modes. Manual (default)
    /// is the baseline and shows nothing; unknown future modes show raw so
    /// new modes surface instead of vanishing.
    var modeSuffix: String {
        guard let mode = permissionMode, !mode.isEmpty, mode != "default" else { return "" }
        switch mode {
        case "plan":              return " · plan"
        case "acceptEdits":       return " · auto-edit"
        case "auto":              return " · auto"
        case "dontAsk":           return " · don't-ask"
        case "bypassPermissions": return " · bypass"
        default:                  return " · \(mode)"
        }
    }
```

In `tooltip` (Model.swift:123), append the mode line right after the first two lines are built:

```swift
    var tooltip: String {
        var lines = [cwd, "\(termProgram) · \(tty.isEmpty ? "tty unknown" : tty)"]
        if let permissionMode, !permissionMode.isEmpty {
            lines.append("mode: \(permissionMode)")
        }
        // …rest unchanged (origin / parked / background / shells lines)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter SessionLabelTests`
Expected: PASS, including all pre-existing tests (exact-equality tooltip tests pass nil mode and are unaffected).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusLight/Model.swift Tests/ClaudeStatusLightTests/SessionLabelTests.swift
git commit -m "Add permissionMode and modeSuffix to SessionState

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: StateStore parses `permission_mode`

**Files:**
- Modify: `Sources/ClaudeStatusLight/StateStore.swift:92-103` (the `SessionState(…)` construction)
- Test: `Tests/ClaudeStatusLightTests/StateStoreTests.swift`

**Interfaces:**
- Consumes: state-file key `"permission_mode"` (Task 1), `SessionState.permissionMode` (Task 2).
- Produces: `activeSessions()` returns sessions with `permissionMode` set (nil when the key is missing or empty).

- [ ] **Step 1: Write the failing tests**

In `Tests/ClaudeStatusLightTests/StateStoreTests.swift`, extend the private `writeSession(…)` helper with a mode parameter:

```swift
    private func writeSession(
        id: String,
        state: String = "idle",
        pid: Int? = nil,
        tty: String = "",
        age: TimeInterval = 0,
        transcriptPath: String? = nil,
        permissionMode: String? = nil
    ) throws -> URL {
        var obj: [String: Any] = [
            "state": state,
            "session_id": id,
            "cwd": "/tmp/proj",
            "term_program": "iTerm.app",
            "tty": tty,
            "updated_at": Date().timeIntervalSince1970 - age,
        ]
        if let pid { obj["pid"] = pid }
        if let transcriptPath { obj["transcript_path"] = transcriptPath }
        if let permissionMode { obj["permission_mode"] = permissionMode }
        let url = dir.appendingPathComponent("\(id).json")
        try JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url
    }
```

Add a test section (after the `// MARK: - Background detection` section):

```swift
    // MARK: - Permission mode

    @Test func parsesPermissionMode() throws {
        _ = try writeSession(id: "planning", pid: Int(ProcessInfo.processInfo.processIdentifier),
                             permissionMode: "plan")
        #expect(store.activeSessions().first?.permissionMode == "plan")
    }

    @Test func missingOrEmptyModeIsNil() throws {
        // The hook writes "" for sessions that never saw a mode; old-format
        // files lack the key entirely. Both mean "unknown".
        _ = try writeSession(id: "empty", pid: Int(ProcessInfo.processInfo.processIdentifier),
                             permissionMode: "")
        _ = try writeSession(id: "legacy")
        for session in store.activeSessions() {
            #expect(session.permissionMode == nil)
        }
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter StateStoreTests`
Expected: `parsesPermissionMode` FAILS (permissionMode is nil — nothing parses it yet). `missingOrEmptyModeIsNil` passes trivially; that's fine, it guards regressions.

- [ ] **Step 3: Implement in StateStore.swift**

In `activeSessions()`, add the argument to the `SessionState(…)` construction (StateStore.swift:92-103), after `shells: shells`:

```swift
            result.append(SessionState(
                sessionID: id,
                state: effectiveState,
                cwd: (obj["cwd"] as? String) ?? "",
                termProgram: (obj["term_program"] as? String) ?? "unknown",
                tty: (obj["tty"] as? String) ?? "",
                pid: pid,
                updatedAt: updatedAt,
                agents: agents,
                title: title(forTranscriptAt: (obj["transcript_path"] as? String) ?? ""),
                shells: shells,
                permissionMode: (obj["permission_mode"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter StateStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusLight/StateStore.swift Tests/ClaudeStatusLightTests/StateStoreTests.swift
git commit -m "Parse permission_mode from session state files

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Show the suffix on panel and menu rows

**Files:**
- Modify: `Sources/ClaudeStatusLight/FloatingPanelController.swift:133`
- Modify: `Sources/ClaudeStatusLight/AppDelegate.swift:175`
- Modify: `README.md` (states table area, ~line 96–105)

**Interfaces:**
- Consumes: `SessionState.modeSuffix` (Task 2).
- Produces: row format `dot displayName modeSuffix shellsSuffix agentsSuffix` on both surfaces.

No new unit test: the row strings are composed inline in UI code and every component (`modeSuffix` included) is unit-tested in `SessionLabelTests`. Verification is compile + full suite + the end-to-end check in Task 6.

- [ ] **Step 1: Update the floating panel row**

`FloatingPanelController.swift:133` — insert `\(session.modeSuffix)` after `displayName`:

```swift
        let button = NSButton(title: "\(session.state.dot) \(session.displayName)\(session.modeSuffix)\(session.shellsSuffix)\(session.agentsSuffix)", target: nil, action: nil)
```

- [ ] **Step 2: Update the menu row**

`AppDelegate.swift:175` — same insertion:

```swift
                let title = "\(session.state.dot) \(session.displayName)\(session.modeSuffix)\(session.shellsSuffix) — \(session.state.label)\(session.agentsSuffix)"
```

- [ ] **Step 3: Document in README**

In `README.md`, directly after the paragraph that explains the state table (the one ending around line 105 discussing the `Notification` reminder and `AskUserQuestion`), add:

```markdown
Rows also show the session's permission mode when it isn't the default —
` · plan`, ` · auto-edit`, ` · bypass`, etc. The hook records the
`permission_mode` field Claude Code sends with most events; the tooltip
always shows the exact value. Toggling modes while idle only becomes
visible on the next hook event (prompt, tool call, or stop).
```

- [ ] **Step 4: Build and run the full Swift suite**

Run: `./scripts/test.sh`
Expected: builds, all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusLight/FloatingPanelController.swift Sources/ClaudeStatusLight/AppDelegate.swift README.md
git commit -m "Show permission mode on panel and menu session rows

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Wire-format parity for remote sessions

**Files:**
- Modify: `Sources/ClaudeStatusLight/RemoteWire.swift` (WireSession struct, init(from:), sessionState(origin:))
- Test: `Tests/ClaudeStatusLightTests/RemoteWireTests.swift`

**Interfaces:**
- Consumes: `SessionState.permissionMode` (Task 2).
- Produces: `WireSession.permissionMode: String?`, JSON key `permission_mode`. Optional in both directions: old JSON without the key decodes to nil; encoders emit it only for the publisher's local truth. The relay stores host sessions as `unknown[]` verbatim (`relay/src/relay-do.ts:7`), so no relay change and no redeploy. `WireCloudSession` unchanged.

- [ ] **Step 1: Write the failing tests**

In `Tests/ClaudeStatusLightTests/RemoteWireTests.swift`:

Extend `wireSessionRoundTripsFromSessionState`: add `permissionMode: "plan"` to the `SessionState(…)` literal (after `shells:`), and add to the expectations:

```swift
        #expect(remote.permissionMode == "plan")
```

Add a new test:

```swift
    @Test func oldWireJsonWithoutModeStillDecodes() throws {
        let json = #"{"session_id":"x","state":"idle","cwd":"/p","term_program":"t","tty":"","updated_at":1,"agents":0,"title":null,"shells":[],"background":false}"#
        let wire = try JSONDecoder().decode(WireSession.self, from: Data(json.utf8))
        #expect(wire.permissionMode == nil)
        #expect(try #require(wire.sessionState(origin: "h")).permissionMode == nil)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh --filter RemoteWireTests`
Expected: FAIL to compile — `extra argument 'permissionMode'` / `no member 'permissionMode'`.

- [ ] **Step 3: Implement in RemoteWire.swift**

Add to `WireSession` after `var background: Bool`:

```swift
    /// Claude Code permission mode ("default", "plan", …). Optional so old
    /// publishers and stored relay snapshots decode cleanly.
    var permissionMode: String?
```

Add the coding key (in the existing enum):

```swift
        case permissionMode = "permission_mode"
```

In `init(from session: SessionState)` add:

```swift
        permissionMode = session.permissionMode
```

In `sessionState(origin:)` add the argument after `backgroundOverride: background`:

```swift
        return SessionState(
            sessionID: sessionID, state: light, cwd: cwd,
            termProgram: termProgram, tty: tty, pid: nil,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            agents: agents, title: title, shells: shells,
            origin: origin, backgroundOverride: background,
            permissionMode: permissionMode
        )
```

`WireCloudSession` is intentionally untouched (cloud payloads don't carry the field end-to-end).

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh --filter RemoteWireTests`
Expected: PASS (including `wireUsesSnakeCaseKeys` — nil optionals are omitted by JSONEncoder, so its exact-key assertions still hold).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusLight/RemoteWire.swift Tests/ClaudeStatusLightTests/RemoteWireTests.swift
git commit -m "Carry permission_mode through the relay wire format

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: Full verification

**Files:** none (verification only)

- [ ] **Step 1: Run everything**

```bash
./scripts/test.sh && bash Tests/hook_test.sh && bash Tests/relay_hook_test.sh
```
Expected: all PASS. (`relay_hook_test.sh` guards the cloud-hook path we didn't touch.)

- [ ] **Step 2: End-to-end eyeball via the verify skill**

Use the project's `verify` skill: build + launch the app, drive `status-hook.sh` with a fake payload containing `"permission_mode":"plan"`, screenshot the floating panel, confirm the row reads `… · plan`. Then fire a payload without the field (Notification-style) and confirm the suffix persists (sticky), and one with `"permission_mode":"default"` and confirm the suffix disappears.

- [ ] **Step 3: Commit any fixes surfaced, no commit if clean**
