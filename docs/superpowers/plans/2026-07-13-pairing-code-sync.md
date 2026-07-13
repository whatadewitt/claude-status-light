# Pairing-Code Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the hand-copy of `~/.claude/status-light/relay.json` with a short-lived pairing code: the main Mac generates a code in Settings, the other Mac runs one `install-publisher.sh --pair` command.

**Architecture:** The existing relay Worker/DO gains two routes — bearer-authed `POST /pair` stores `{url, token}` under a random 128-bit code for 10 minutes; unauthenticated `GET /pair/:code` returns it exactly once (delete-on-read, uniform 404). The Mac app gains a "Pair another machine…" Settings button that POSTs its own config and shows the paste-ready command in a sheet. `install-publisher.sh` gains a `--pair <url> <code>` flag that fetches the config, writes `relay.json` with the local short hostname, and falls through to the existing build + launchd path.

**Tech Stack:** Cloudflare Worker + Durable Object (TypeScript, vitest + `@cloudflare/vitest-pool-workers`), Swift/AppKit (swift-testing), bash + python3.

**Spec:** `docs/superpowers/specs/2026-07-13-pairing-code-sync-design.md`

## Global Constraints

- Codes are 128-bit random, rendered as **32 lowercase hex chars**; TTL is exactly **10 minutes** (`PAIR_TTL_S = 10 * 60`). No rate limiting — entropy is the defense.
- `GET /pair/:code` returns the config **exactly once** (delete-on-read). Unknown, expired, and already-used codes are indistinguishable: uniform `404` with body `not found`.
- After ANY change under `relay/src`, run `scripts/build-relay-dist.sh` and commit the regenerated `Sources/ClaudeStatusLight/RelayWorkerDist.swift` — `RelayWorkerDistTests` fails the Swift suite otherwise.
- Settings button title is exactly `Pair another machine…`, visible only when `RelayConfig.load()` is non-nil.
- The command the sheet shows is exactly `scripts/install-publisher.sh --pair <url> <code>`; the expiry note is `Expires in 10 minutes, works once.`
- The script's 404 error message contains `code expired or already used — generate a new one from Settings on your main Mac.`
- `relay.json` written by `--pair` has mode `600` and `host` set to the **local** short hostname (`socket.gethostname().split(".")[0]`).
- Test commands: relay = `cd relay && npm test`; Swift = `bash scripts/test.sh`; script smoke = `bash Tests/pair_test.sh`.
- Work on a feature branch (worktree), NOT directly on `main`. Merge target is `main`, only after Luke's manual test and explicit OK.
- Commit messages: imperative mood, matching repo history; end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Relay DO — `POST /pair` and `GET /pair/:code`

**Files:**
- Modify: `relay/src/relay-do.ts`
- Test: `relay/test/relay-do.test.ts`

**Interfaces:**
- Consumes: existing `RelayDO.fetch` routing and `snapshot()` pruning pattern.
- Produces: `PAIR_TTL_S: number` exported from `relay/src/relay-do.ts`; DO routes `POST /pair` (body `{url: string, token: string}` → 200 `{code: string, expires_at: number}`, 400 on bad body) and `GET /pair/<code>` (200 `{url, token}` once, else 404 `not found`). Storage keys `pair:<code>` holding `{url, token, expires_at}` (absolute epoch seconds). Task 2 (worker) and Task 6 (script) rely on these exact shapes.

- [ ] **Step 1: Write the failing tests**

Append to `relay/test/relay-do.test.ts`. Two import changes at the top of the file: extend the existing `../src/relay-do` type-only import and add `PAIR_TTL_S`:

```ts
// replace:  import type { RelayDO } from "../src/relay-do";
import { PAIR_TTL_S } from "../src/relay-do";
import type { RelayDO } from "../src/relay-do";
```

Append this describe block at the end of the file:

```ts
describe("pairing codes", () => {
  const config = { url: "https://relay.example", token: "secret-token" };

  /// Backdates a stored pair record so its TTL has elapsed.
  async function expire(stub: DurableObjectStub, code: string) {
    await runInDurableObject(stub, async (instance: RelayDO) => {
      const ctx = (instance as unknown as { ctx: DurableObjectState }).ctx;
      const record = await ctx.storage.get<{ expires_at: number }>(`pair:${code}`);
      await ctx.storage.put(`pair:${code}`, {
        ...record!,
        expires_at: record!.expires_at - PAIR_TTL_S - 10,
      });
    });
  }

  it("round-trips a config through POST /pair and GET /pair/:code", async () => {
    const stub = relay();
    const res = await post(stub, "/pair", config);
    expect(res.status).toBe(200);
    const { code, expires_at } = (await res.json()) as { code: string; expires_at: number };
    expect(code).toMatch(/^[0-9a-f]{32}$/);
    const drift = Math.abs(expires_at - Math.floor(Date.now() / 1000) - PAIR_TTL_S);
    expect(drift).toBeLessThan(5);

    const redeemed = await stub.fetch(`https://relay/pair/${code}`);
    expect(redeemed.status).toBe(200);
    expect(await redeemed.json()).toEqual(config);
  });

  it("returns the config exactly once", async () => {
    const stub = relay();
    const res = await post(stub, "/pair", config);
    const { code } = (await res.json()) as { code: string };
    expect((await stub.fetch(`https://relay/pair/${code}`)).status).toBe(200);
    expect((await stub.fetch(`https://relay/pair/${code}`)).status).toBe(404);
  });

  it("404s an expired code and removes it from storage", async () => {
    const stub = relay();
    const res = await post(stub, "/pair", config);
    const { code } = (await res.json()) as { code: string };
    await expire(stub, code);
    expect((await stub.fetch(`https://relay/pair/${code}`)).status).toBe(404);
    await runInDurableObject(stub, async (instance: RelayDO) => {
      const ctx = (instance as unknown as { ctx: DurableObjectState }).ctx;
      expect(await ctx.storage.get(`pair:${code}`)).toBeUndefined();
    });
  });

  it("answers unknown, expired, and used codes identically (no oracle)", async () => {
    const stub = relay();
    const first = (await (await post(stub, "/pair", config)).json()) as { code: string };
    await stub.fetch(`https://relay/pair/${first.code}`); // consume it
    const used = await stub.fetch(`https://relay/pair/${first.code}`);

    const second = (await (await post(stub, "/pair", config)).json()) as { code: string };
    await expire(stub, second.code);
    const expired = await stub.fetch(`https://relay/pair/${second.code}`);

    const unknown = await stub.fetch(`https://relay/pair/${"0".repeat(32)}`);

    const all = [used, expired, unknown];
    for (const res of all) expect(res.status).toBe(404);
    const bodies = await Promise.all(all.map((r) => r.text()));
    expect(new Set(bodies).size).toBe(1);
  });

  it("rejects bodies missing url or token", async () => {
    const stub = relay();
    expect((await post(stub, "/pair", {})).status).toBe(400);
    expect((await post(stub, "/pair", { url: "https://x" })).status).toBe(400);
    expect((await post(stub, "/pair", { url: "", token: "t" })).status).toBe(400);
    expect((await post(stub, "/pair", { url: "https://x", token: "" })).status).toBe(400);
  });

  it("never leaks pairing state into /sessions", async () => {
    const stub = relay();
    await post(stub, "/pair", config);
    const body = await sessions(stub);
    expect(body.hosts).toEqual([]);
    expect(body.cloud).toEqual([]);
    expect(JSON.stringify(body)).not.toContain("secret-token");
  });

  it("prunes expired codes during a snapshot", async () => {
    const stub = relay();
    const { code } = (await (await post(stub, "/pair", config)).json()) as { code: string };
    await expire(stub, code);
    await sessions(stub);
    await runInDurableObject(stub, async (instance: RelayDO) => {
      const ctx = (instance as unknown as { ctx: DurableObjectState }).ctx;
      expect(await ctx.storage.get(`pair:${code}`)).toBeUndefined();
    });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd relay && npm test`
Expected: the new `pairing codes` tests FAIL (404s from unrouted `/pair`, and a TS/import error for `PAIR_TTL_S` until it exists — if the import breaks compilation, that IS the failure signal). Pre-existing tests still pass.

- [ ] **Step 3: Implement the DO routes**

In `relay/src/relay-do.ts`, add below the `CloudRecord` interface:

```ts
interface PairRecord {
  url: string;
  token: string;
  expires_at: number;
}

/// Pairing codes hand the relay config to a new machine. Single-use,
/// short-lived, 128-bit — the code itself is the credential, so entropy
/// (not rate limiting) is the defense.
export const PAIR_TTL_S = 10 * 60;
```

In `fetch()`, insert between the `POST /hook` block and the `GET /sessions` block:

```ts
    if (request.method === "POST" && url.pathname === "/pair") {
      const body = (await request.json().catch(() => null)) as
        { url?: unknown; token?: unknown } | null;
      if (!body || typeof body.url !== "string" || !body.url ||
          typeof body.token !== "string" || !body.token) {
        return new Response("invalid body", { status: 400 });
      }
      const bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      const code = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
      const record: PairRecord = { url: body.url, token: body.token, expires_at: now + PAIR_TTL_S };
      await this.ctx.storage.put(`pair:${code}`, record);
      return Response.json({ code, expires_at: record.expires_at });
    }

    if (request.method === "GET" && url.pathname.startsWith("/pair/")) {
      const code = url.pathname.slice("/pair/".length);
      const record = await this.ctx.storage.get<PairRecord>(`pair:${code}`);
      // Delete before returning (single-use), and answer unknown, expired,
      // and already-used codes identically — a uniform 404 gives no oracle.
      if (record) {
        await this.ctx.storage.delete(`pair:${code}`);
        if (record.expires_at > now) {
          return Response.json({ url: record.url, token: record.token });
        }
      }
      return new Response("not found", { status: 404 });
    }
```

In `snapshot()`, add a third branch to the `for` loop after the `cloud:` branch:

```ts
      } else if (key.startsWith("pair:")) {
        // Never included in the response; lazy pruning only, so codes
        // don't outlive their TTL in storage.
        if ((value as PairRecord).expires_at <= now) {
          await this.ctx.storage.delete(key);
        }
      }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd relay && npm test`
Expected: ALL tests PASS (new pairing block plus every pre-existing test).

- [ ] **Step 5: Commit**

```bash
git add relay/src/relay-do.ts relay/test/relay-do.test.ts
git commit -m "Add single-use pairing-code storage to the relay DO"
```

(Note: the Swift suite is now red on `RelayWorkerDistTests` until Task 3 regenerates the dist — that's expected mid-stream; Task 3 fixes it before any Swift work.)

---

### Task 2: Worker auth carve-out for `GET /pair/:code`

**Files:**
- Modify: `relay/src/index.ts`
- Test: `relay/test/worker.test.ts`

**Interfaces:**
- Consumes: Task 1's DO routes.
- Produces: the deployed Worker forwards unauthenticated `GET /pair/<anything>` to the DO; every other route still requires the bearer token. Task 6's `curl` (no auth header) relies on this.

- [ ] **Step 1: Write the failing tests**

Append to `relay/test/worker.test.ts`:

```ts
describe("pair redemption through the worker", () => {
  it("POST /pair requires auth; GET /pair/<code> does not", async () => {
    const unauthedPost = await exports.default.fetch(
      request("/pair", { method: "POST", body: JSON.stringify({ url: "https://r", token: "t" }) }),
    );
    expect(unauthedPost.status).toBe(401);

    const created = await exports.default.fetch(
      request(
        "/pair",
        { method: "POST", body: JSON.stringify({ url: "https://r.example", token: "tok" }) },
        "test-token",
      ),
    );
    expect(created.status).toBe(200);
    const { code } = (await created.json()) as { code: string };

    const redeemed = await exports.default.fetch(request(`/pair/${code}`));
    expect(redeemed.status).toBe(200);
    expect(await redeemed.json()).toEqual({ url: "https://r.example", token: "tok" });
  });

  it("unauthenticated GET of an unknown code is 404, not 401", async () => {
    const res = await exports.default.fetch(request(`/pair/${"f".repeat(32)}`));
    expect(res.status).toBe(404);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd relay && npm test`
Expected: both new tests FAIL — the unauthenticated GETs return 401.

- [ ] **Step 3: Implement the carve-out**

In `relay/src/index.ts`, replace the body of the default export's `fetch` with:

```ts
  async fetch(request, env, _ctx): Promise<Response> {
    // GET /pair/<code> is the one unauthenticated route: it exists for a
    // machine that doesn't have the bearer token yet, and the 128-bit
    // single-use code is its own credential (see relay-do.ts).
    const url = new URL(request.url);
    const pairRedeem = request.method === "GET" && url.pathname.startsWith("/pair/");
    if (!pairRedeem && !(await authorized(request, env))) {
      return new Response("unauthorized", { status: 401 });
    }
    // One DO holds all state: strong consistency, one clock for all
    // staleness math (KV's cross-edge lag would show stale lights).
    const stub = env.RELAY.get(env.RELAY.idFromName("singleton"));
    return stub.fetch(request);
  },
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd relay && npm test`
Expected: ALL tests PASS, including the pre-existing auth tests (`/sessions` still 401s without a token).

- [ ] **Step 5: Commit**

```bash
git add relay/src/index.ts relay/test/worker.test.ts
git commit -m "Let pairing-code redemption through the Worker without auth"
```

---

### Task 3: Regenerate the bundled Worker dist

**Files:**
- Regenerate: `Sources/ClaudeStatusLight/RelayWorkerDist.swift` (via `scripts/build-relay-dist.sh` — never hand-edit)

**Interfaces:**
- Consumes: Tasks 1–2's `relay/src` changes.
- Produces: an in-app deploy (Settings → Re-deploy relay…) that ships the pairing routes; a green `RelayWorkerDistTests`.

- [ ] **Step 1: Verify the guard test currently fails**

Run: `bash scripts/test.sh --filter RelayWorkerDistTests`
Expected: FAIL with "relay/src changed — run scripts/build-relay-dist.sh and commit the result".

- [ ] **Step 2: Regenerate**

Run: `bash scripts/build-relay-dist.sh`
Expected: `wrote .../Sources/ClaudeStatusLight/RelayWorkerDist.swift (source hash <64 hex chars>)`.

- [ ] **Step 3: Run the guard test to verify it passes**

Run: `bash scripts/test.sh --filter RelayWorkerDistTests`
Expected: PASS (both `distMatchesRelaySources` and `distLooksLikeTheBundledWorker`).

- [ ] **Step 4: Commit**

```bash
git add Sources/ClaudeStatusLight/RelayWorkerDist.swift
git commit -m "Regenerate bundled Worker with the pairing routes"
```

---

### Task 4: Swift pure pairing helpers

**Files:**
- Create: `Sources/ClaudeStatusLight/Pairing.swift`
- Test: `Tests/ClaudeStatusLightTests/PairingTests.swift`

**Interfaces:**
- Consumes: `RelayConfig` (`url: URL`, `token: String`, `host: String`).
- Produces: `Pairing.request(config:) -> URLRequest?`, `Pairing.decode(_: Data) -> Pairing.Response?` (`Response` has `code: String`, `expiresAt: Int`), `Pairing.command(url:code:) -> String`. Task 5's sheet wiring calls exactly these.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ClaudeStatusLightTests/PairingTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeStatusLight

struct PairingTests {
    private let config = RelayConfig(
        url: URL(string: "https://claude-status-relay.luke.workers.dev")!,
        token: "tok", host: "studio")

    @Test func requestPostsConfigToPairWithBearer() throws {
        let request = try #require(Pairing.request(config: config))
        #expect(request.url?.absoluteString
                == "https://claude-status-relay.luke.workers.dev/pair")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        let body = try #require(request.httpBody)
        let obj = try #require(try JSONSerialization.jsonObject(with: body) as? [String: String])
        // No "host": the receiving machine writes its own.
        #expect(obj == ["url": "https://claude-status-relay.luke.workers.dev", "token": "tok"])
    }

    @Test func decodeParsesCodeAndExpiry() {
        let data = Data(#"{"code":"abc123","expires_at":1752000600}"#.utf8)
        #expect(Pairing.decode(data) == Pairing.Response(code: "abc123", expiresAt: 1_752_000_600))
    }

    @Test func decodeRejectsGarbageAndEmptyCodes() {
        #expect(Pairing.decode(Data("nope".utf8)) == nil)
        #expect(Pairing.decode(Data(#"{"code":"","expires_at":1}"#.utf8)) == nil)
        #expect(Pairing.decode(Data(#"{"expires_at":1}"#.utf8)) == nil)
    }

    @Test func commandMatchesInstallPublisherFlag() {
        #expect(Pairing.command(url: config.url, code: "cafe01") ==
            "scripts/install-publisher.sh --pair https://claude-status-relay.luke.workers.dev cafe01")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/test.sh --filter PairingTests`
Expected: BUILD FAILURE — `cannot find 'Pairing' in scope`. (A compile error is this step's expected "failing test".)

- [ ] **Step 3: Implement `Pairing`**

Create `Sources/ClaudeStatusLight/Pairing.swift`:

```swift
import Foundation

/// Pure pieces of "Pair another machine…": the /pair request, its response,
/// and the command string pasted on the other Mac. The AppKit glue that
/// shows the result lives in PairSheet.swift.
enum Pairing {
    /// What POST /pair returns: the single-use code plus its expiry stamp.
    struct Response: Decodable, Equatable {
        let code: String
        let expiresAt: Int

        enum CodingKeys: String, CodingKey {
            case code
            case expiresAt = "expires_at"
        }
    }

    /// POST /pair carrying the relay config the other machine will receive.
    /// `host` is deliberately absent — the receiver writes its own.
    static func request(config: RelayConfig) -> URLRequest? {
        guard let url = URL(string: "pair", relativeTo: config.url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["url": config.url.absoluteString, "token": config.token],
            options: [.sortedKeys])
        return request
    }

    static func decode(_ data: Data) -> Response? {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.code.isEmpty else { return nil }
        return response
    }

    /// The exact line the user pastes on the other Mac (from a clone of this
    /// repo) — must match install-publisher.sh's --pair flag.
    static func command(url: URL, code: String) -> String {
        "scripts/install-publisher.sh --pair \(url.absoluteString) \(code)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash scripts/test.sh --filter PairingTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusLight/Pairing.swift Tests/ClaudeStatusLightTests/PairingTests.swift
git commit -m "Add pure request/response/command helpers for pairing"
```

---

### Task 5: Pair sheet and Settings button

**Files:**
- Create: `Sources/ClaudeStatusLight/PairSheet.swift`
- Modify: `Sources/ClaudeStatusLight/SettingsWindowController.swift`
- Test: `Tests/ClaudeStatusLightTests/SettingsRelayTests.swift`

**Interfaces:**
- Consumes: `Pairing.request/decode/command` (Task 4), `ClosureInvoker` (in `Controls.swift`), the `DeployProgressSheet` presentation pattern already in `SettingsWindowController.swift`.
- Produces: `PairSheet` (`show(command:)`, `fail(_:)`, `onCancel`), `SettingsWindowController.pairButtonHidden(config:) -> Bool`, and the wired-up button.

- [ ] **Step 1: Write the failing visibility test**

In `Tests/ClaudeStatusLightTests/SettingsRelayTests.swift`, add inside `struct SettingsRelayTests`:

```swift
    @Test func pairButtonOnlyShowsWhenConfigured() {
        #expect(SettingsWindowController.pairButtonHidden(config: nil))
        let config = RelayConfig(url: URL(string: "https://x")!, token: "t", host: "h")
        #expect(!SettingsWindowController.pairButtonHidden(config: config))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/test.sh --filter SettingsRelayTests`
Expected: BUILD FAILURE — `type 'SettingsWindowController' has no member 'pairButtonHidden'`.

- [ ] **Step 3: Create the sheet**

Create `Sources/ClaudeStatusLight/PairSheet.swift`:

```swift
import AppKit

/// Modal sheet for "Pair another machine…": shows the single-use command
/// once the relay hands back a code, or the failure if it didn't. Same
/// shape as DeployProgressSheet: @MainActor, ClosureInvoker targets,
/// retained by the controller until dismissed.
@MainActor
final class PairSheet {
    let window: NSWindow
    private let status = NSTextField(wrappingLabelWithString: "Requesting pairing code…")
    private let command = NSTextField(wrappingLabelWithString: "")
    private let note = NSTextField(labelWithString: "Expires in 10 minutes, works once.")
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let close = NSButton(title: "Cancel", target: nil, action: nil)
    private var invokers: [ClosureInvoker] = []
    /// Invoked when the user dismisses the sheet — the caller cancels a
    /// still-in-flight request task.
    var onCancel: (() -> Void)?

    init() {
        window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Pair another machine"

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        status.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(status)

        command.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        command.preferredMaxLayoutWidth = 360
        command.isSelectable = true
        command.isHidden = true
        stack.addArrangedSubview(command)

        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.isHidden = true
        stack.addArrangedSubview(note)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8
        copyButton.bezelStyle = .rounded
        copyButton.isHidden = true
        let copyInvoker = ClosureInvoker { [weak self] in self?.copyCommand() }
        copyButton.target = copyInvoker
        copyButton.action = #selector(ClosureInvoker.fire)
        invokers.append(copyInvoker)
        buttons.addArrangedSubview(copyButton)

        close.bezelStyle = .rounded
        let closeInvoker = ClosureInvoker { [weak self] in self?.dismiss() }
        close.target = closeInvoker
        close.action = #selector(ClosureInvoker.fire)
        invokers.append(closeInvoker)
        buttons.addArrangedSubview(close)
        stack.addArrangedSubview(buttons)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
        ])
        window.contentView = content
        resize()
    }

    func show(command commandText: String) {
        status.stringValue = "Run this on the other Mac (with this repo cloned):"
        command.stringValue = commandText
        command.isHidden = false
        note.isHidden = false
        copyButton.isHidden = false
        close.title = "Close"
        resize()
    }

    func fail(_ message: String) {
        status.stringValue = "✗ " + message
        close.title = "Close"
        resize()
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command.stringValue, forType: .string)
    }

    private func dismiss() {
        onCancel?()
        window.sheetParent?.endSheet(window)
    }

    private func resize() {
        window.setContentSize(window.contentView!.fittingSize)
    }
}
```

- [ ] **Step 4: Wire the button into SettingsWindowController**

In `Sources/ClaudeStatusLight/SettingsWindowController.swift`:

(a) Add properties after `private var activeSheet: DeployProgressSheet?`:

```swift
    private var pairButton: NSButton?
    private var pairTask: Task<Void, Never>?
    /// Retained for the same reason as activeSheet.
    private var activePairSheet: PairSheet?
```

(b) In `build()`, immediately after `stack.addArrangedSubview(deploy)`:

```swift
        let pair = NSButton(title: "Pair another machine…", target: nil, action: nil)
        pair.bezelStyle = .rounded
        let pairInvoker = ClosureInvoker { [weak self] in self?.runPair() }
        pair.target = pairInvoker
        pair.action = #selector(ClosureInvoker.fire)
        invokers.append(pairInvoker)
        pair.isHidden = Self.pairButtonHidden(config: relayConfig)
        pairButton = pair
        stack.addArrangedSubview(pair)
```

(c) In `runDeploy()`'s success path, after `self?.onRelayChanged?()`:

```swift
                    self?.pairButton?.isHidden = false
```

(d) Next to the other static helpers (`relayStatusText`/`relayButtonTitle`):

```swift
    /// Pairing hands out THIS machine's relay config — pointless (and a
    /// guaranteed failure) before one exists.
    static func pairButtonHidden(config: RelayConfig?) -> Bool {
        config == nil
    }
```

(e) Add the action after `runDeploy()`:

```swift
    private func runPair() {
        // Same main-thread reality as runDeploy: assert it so the
        // @MainActor PairSheet can be constructed without an await.
        MainActor.assumeIsolated {
            guard pairTask == nil, let window, let config = RelayConfig.load() else { return }
            let sheet = PairSheet()
            activePairSheet = sheet
            window.beginSheet(sheet.window) { [weak self] _ in
                self?.activePairSheet = nil
                self?.pairButton?.isEnabled = true
            }
            pairButton?.isEnabled = false
            sheet.onCancel = { [weak self] in self?.pairTask?.cancel() }

            pairTask = Task { @MainActor [weak self] in
                defer { self?.pairTask = nil }
                do {
                    guard let request = Pairing.request(config: config) else {
                        sheet.fail("Relay URL is malformed — re-run the relay setup.")
                        return
                    }
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          let decoded = Pairing.decode(data) else {
                        sheet.fail("The relay refused the pairing request — "
                                   + "re-deploy the relay (it may predate pairing) and try again.")
                        return
                    }
                    sheet.show(command: Pairing.command(url: config.url, code: decoded.code))
                } catch is CancellationError {
                    // The user already dismissed the sheet; leave it alone.
                } catch {
                    sheet.fail(error.localizedDescription)
                }
            }
        }
    }
```

- [ ] **Step 5: Run the full Swift suite**

Run: `bash scripts/test.sh`
Expected: ALL tests PASS (including the new `pairButtonOnlyShowsWhenConfigured`).

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusLight/PairSheet.swift Sources/ClaudeStatusLight/SettingsWindowController.swift Tests/ClaudeStatusLightTests/SettingsRelayTests.swift
git commit -m "Add the Pair another machine sheet to Settings"
```

---

### Task 6: `install-publisher.sh --pair`, smoke test, CI wiring

**Files:**
- Modify: `scripts/install-publisher.sh`
- Create: `Tests/pair_test.sh`
- Modify: `.github/workflows/ci.yml` (the `scripts` job)

**Interfaces:**
- Consumes: `GET <url>/pair/<code>` returning `{url, token}` on 200, plain 404 otherwise (Tasks 1–2).
- Produces: `scripts/install-publisher.sh --pair <url> <code>` — the exact command Task 5's sheet emits.

- [ ] **Step 1: Write the failing smoke test**

Create `Tests/pair_test.sh` (make it executable: `chmod +x Tests/pair_test.sh`):

```bash
#!/bin/bash
# Smoke-test install-publisher.sh --pair against a stub relay: the success
# path must write relay.json (local short hostname, mode 600) before the
# build step, and the 404 path must exit with guidance. A fake `swift` on
# PATH halts the script right after the config is written, so this never
# builds anything or touches launchd.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export HOME="$(mktemp -d)"
CODE="abababababababababababababababab"
CONFIG="$HOME/.claude/status-light/relay.json"

cat > "$HOME/stub.py" <<'PY'
import http.server, json, sys

CODE = sys.argv[1]
used = False

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global used
        if self.path == f"/pair/{CODE}" and not used:
            used = True
            body = json.dumps({"url": "https://relay.example", "token": "tok123"}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_error(404)

    def log_message(self, *args):
        pass

server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
PY
python3 "$HOME/stub.py" "$CODE" > "$HOME/port.txt" &
STUB_PID=$!
trap 'kill "$STUB_PID" 2>/dev/null || true' EXIT
for _ in $(seq 50); do [ -s "$HOME/port.txt" ] && break; sleep 0.1; done
BASE="http://127.0.0.1:$(cat "$HOME/port.txt")"

mkdir -p "$HOME/fakebin"
printf '#!/bin/sh\nexit 7\n' > "$HOME/fakebin/swift"
chmod +x "$HOME/fakebin/swift"
export PATH="$HOME/fakebin:$PATH"

echo "--- success path writes relay.json, then stops at the fake build"
set +e
bash "$HERE/scripts/install-publisher.sh" --pair "$BASE" "$CODE"
STATUS=$?
set -e
[ "$STATUS" -eq 7 ] || { echo "FAIL: expected exit 7 from fake swift, got $STATUS"; exit 1; }
[ -f "$CONFIG" ] || { echo "FAIL: relay.json not written"; exit 1; }
python3 - "$CONFIG" <<'PY'
import json, os, socket, sys
path = sys.argv[1]
config = json.load(open(path))
assert config["url"] == "https://relay.example", config
assert config["token"] == "tok123", config
assert config["host"] == socket.gethostname().split(".")[0], config
mode = os.stat(path).st_mode & 0o777
assert mode == 0o600, oct(mode)
print("relay.json checks passed")
PY

echo "--- second redemption of the same code fails with guidance"
rm "$CONFIG"
set +e
OUT="$(bash "$HERE/scripts/install-publisher.sh" --pair "$BASE" "$CODE" 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || { echo "FAIL: expected exit 1 on 404, got $STATUS"; exit 1; }
echo "$OUT" | grep -q "expired or already used" || { echo "FAIL: missing guidance in: $OUT"; exit 1; }
[ ! -f "$CONFIG" ] || { echo "FAIL: relay.json written despite 404"; exit 1; }

echo "--- --pair with a missing code errors out"
set +e
bash "$HERE/scripts/install-publisher.sh" --pair "$BASE" >/dev/null 2>&1
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || { echo "FAIL: expected exit 1 for missing code, got $STATUS"; exit 1; }

echo "pair_test.sh: all checks passed"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash Tests/pair_test.sh`
Expected: FAIL at the first check — today's script rejects `--pair` as `unknown argument` (exit 1, not 7).

- [ ] **Step 3: Implement `--pair`**

In `scripts/install-publisher.sh`:

(a) Replace the header comment's last paragraph (the two lines starting `# Expects ~/.claude/status-light/relay.json…`) with:

```bash
# Config comes from one of (checked in this order):
#   --pair <url> <code>          fetch it with a code from Settings →
#                                "Pair another machine…" on the main Mac
#   --url <u> --token <t> [--host <label>]
#   an existing ~/.claude/status-light/relay.json (copied by hand)
```

(b) Replace the argument loop and the `if [ -n "$URL" ]…fi` block with:

```bash
URL="" TOKEN="" HOST="" PAIR_URL="" PAIR_CODE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --url)   URL="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        --host)  HOST="$2"; shift 2 ;;
        --pair)
            [ $# -ge 3 ] || { echo "--pair needs <url> <code>" >&2; exit 1; }
            PAIR_URL="$2"; PAIR_CODE="$3"; shift 3 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -n "$PAIR_URL" ] && [ -n "$PAIR_CODE" ]; then
    echo "Fetching relay config…"
    BODY="$(curl -fsS "${PAIR_URL%/}/pair/$PAIR_CODE")" || {
        echo "code expired or already used — generate a new one from Settings on your main Mac." >&2
        exit 1
    }
    mkdir -p "$(dirname "$CONFIG")"
    python3 - "$CONFIG" "$BODY" <<'PY'
import json, socket, sys
path, body = sys.argv[1:3]
config = json.loads(body)
json.dump({"url": config["url"], "token": config["token"],
           "host": socket.gethostname().split(".")[0]},
          open(path, "w"), indent=2)
PY
    chmod 600 "$CONFIG"
elif [ -n "$URL" ] && [ -n "$TOKEN" ]; then
    mkdir -p "$(dirname "$CONFIG")"
    python3 - "$CONFIG" "$URL" "$TOKEN" "$HOST" <<'PY'
import json, socket, sys
path, url, token, host = sys.argv[1:5]
json.dump({"url": url, "token": token,
           "host": host or socket.gethostname().split(".")[0]},
          open(path, "w"), indent=2)
PY
    chmod 600 "$CONFIG"
fi
```

(The `elif` branch is today's `--url/--token` writer, unchanged.)

- [ ] **Step 4: Run the smoke test to verify it passes**

Run: `bash -n scripts/install-publisher.sh && bash -n Tests/pair_test.sh && bash Tests/pair_test.sh`
Expected: ends with `pair_test.sh: all checks passed`.

- [ ] **Step 5: Wire into CI**

In `.github/workflows/ci.yml`, `scripts` job:

(a) Append to the `Shell syntax` step's `run` block:

```yaml
          bash -n scripts/install-publisher.sh
          bash -n Tests/pair_test.sh
```

(b) After the `Hook behavior` step, add:

```yaml
      - name: Pairing flow (install-publisher.sh --pair)
        run: bash Tests/pair_test.sh
```

- [ ] **Step 6: Commit**

```bash
git add scripts/install-publisher.sh Tests/pair_test.sh .github/workflows/ci.yml
git commit -m "Grow install-publisher.sh a --pair flag with CI smoke checks"
```

---

### Task 7: Documentation

**Files:**
- Modify: `README.md` (the "Each remote Mac" bullet, ~line 132)
- Modify: `TODO.md` (the "Pairing-code sync" bullet under "Remote sessions — future work")

**Interfaces:**
- Consumes: everything above; no code.

- [ ] **Step 1: Update README**

Replace the bullet

```markdown
- **Each remote Mac:** copy `relay.json` over (edit `"host"` to a label you'll
  recognize), then run `scripts/install-publisher.sh` there. It builds the same
  binary and registers a launchd agent that runs `claude-status-light --publish`,
  mirroring that Mac's local session files to the relay.
```

with

```markdown
- **Each remote Mac:** in Settings on the main Mac, click **Pair another
  machine…** — it shows a one-liner like
  `scripts/install-publisher.sh --pair <url> <code>` (code is single-use,
  expires in 10 minutes). Run that from a clone of this repo on the remote
  Mac: it fetches the relay config, writes `relay.json` with that Mac's own
  hostname, builds the same binary, and registers a launchd agent that runs
  `claude-status-light --publish`. (Manual fallback: copy `relay.json` over,
  edit `"host"`, and run `scripts/install-publisher.sh` bare.)
```

- [ ] **Step 2: Update TODO.md**

Replace the whole bullet

```markdown
- **Pairing-code sync for other machines.** (next up) Instead of copying
  relay.json by hand: main Mac POSTs the config to a `/pair` endpoint
  (bearer-authed) and shows a short-lived, single-use, high-entropy code;
  the other machine enters URL + code, fetches the config once, writes
  relay.json. Same Worker/DO, two new routes; receiving end could be a
  `--pair` flag grown by install-publisher.sh or a first-launch prompt.
```

with

```markdown
- **First-launch pairing prompt for viewer Macs.** Pairing now covers
  publisher setup (`install-publisher.sh --pair`), but a Mac that only
  *views* remote sessions still copies relay.json by hand — offer a
  paste-a-code prompt in the app itself.
```

- [ ] **Step 3: Commit**

```bash
git add README.md TODO.md
git commit -m "Document pairing-code setup for remote Macs"
```

---

### Task 8: Full verification

- [ ] **Step 1: Run every suite**

```bash
cd relay && npm test && cd ..
bash scripts/test.sh
bash Tests/pair_test.sh
bash Tests/hook_test.sh
```

Expected: all PASS.

- [ ] **Step 2: Confirm the working tree is clean and every commit is in place**

Run: `git status && git log --oneline -8`
Expected: clean tree; commits from Tasks 1–7 present.

**Post-merge, manual (Luke):** the new routes only exist in production after a re-deploy (Settings → Re-deploy relay…, or `scripts/deploy-relay.sh`). Note the spec's reality check: the first real in-app deploy is still unexercised — test it alongside this. Then the end-to-end pairing test: Settings → Pair another machine… on the main Mac, paste the command on another Mac.
