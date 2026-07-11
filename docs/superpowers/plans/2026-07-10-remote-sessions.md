# Remote Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show Claude Code sessions from other machines and cloud sandboxes in the menu bar app, per the approved spec `docs/superpowers/specs/2026-07-10-remote-sessions-design.md`.

**Architecture:** A Cloudflare Worker fronting one Durable Object stores session state. Owned Macs run the existing binary in a new headless `--publish` mode that snapshots the already-derived local `StateStore` sessions to the Worker; cloud sandboxes POST raw hook payloads from a repo-committed hook and the Worker classifies them server-side. The app polls `GET /sessions` and merges remote rows (origin-labeled, non-clickable) with local ones.

**Tech Stack:** Swift 6 toolchain (language mode v5, macOS 12+, no third-party Swift deps) · TypeScript Cloudflare Worker + Durable Object · vitest ≥4.1 with `@cloudflare/vitest-pool-workers` · bash hooks (no jq) · wrangler v4.

## Global Constraints

- Wire format times are **epoch seconds** (numbers), everywhere.
- Thresholds: app poll **4 s** · publisher heartbeat **15 s** (loop tick 2 s) · host stale **60 s** (app-side) · cloud TTL **1800 s** (DO prune + app filter) · DO host prune **86400 s**.
- Hook scripts always `exit 0`, never block (curl `-m 2`, backgrounded), no jq.
- No secrets committed: relay token only via `wrangler secret put RELAY_TOKEN` and `~/.claude/status-light/relay.json` (chmod 600). Token comparison must be timing-safe (SHA-256 digests + `crypto.subtle.timingSafeEqual`).
- Worker config: `wrangler.jsonc`, `compatibility_date: "2026-07-10"`, `nodejs_compat`, observability enabled, DO registered via `new_sqlite_classes` migration. Never hand-write `Env` — generate with `npx wrangler types`.
- Swift tests run with `./scripts/test.sh`; relay tests with `cd relay && npx vitest run`; hook tests are standalone bash files under `Tests/`.
- Swift: new `SessionState` fields must be `var` with `= nil` defaults declared **after** `shells` so existing memberwise-init call sites keep compiling.

---

### Task 1: Relay package scaffold + pure classification module

**Files:**
- Create: `relay/package.json`, `relay/wrangler.jsonc`, `relay/tsconfig.json`, `relay/vitest.config.ts`, `relay/.gitignore`
- Create: `relay/src/classify.ts`
- Create: `relay/src/index.ts` (stub — full version in Task 3), `relay/src/relay-do.ts` (stub — full version in Task 2; wrangler types needs the config to resolve)
- Test: `relay/test/classify.test.ts`

**Interfaces:**
- Consumes: nothing.
- Produces: `classify(payload: Record<string, unknown>): HookAction` · `type HookAction = { kind: "set"; state: "idle" | "working" | "attention" } | { kind: "delete" } | { kind: "agents"; delta: 1 | -1 } | { kind: "ignore" }` · `repoName(cwd: unknown): string | null` · `cloudExpired(receivedAt: number, now: number): boolean` · `hostExpired(receivedAt: number, now: number): boolean` · constants `CLOUD_TTL_S = 1800`, `HOST_PRUNE_S = 86400`.

- [ ] **Step 1: Scaffold the package**

`relay/package.json`:

```json
{
  "name": "claude-status-relay",
  "private": true,
  "scripts": {
    "test": "vitest run",
    "types": "wrangler types",
    "deploy": "wrangler deploy"
  },
  "devDependencies": {
    "@cloudflare/vitest-pool-workers": "^0.18.0",
    "typescript": "^5.9.0",
    "vitest": "^4.1.0",
    "wrangler": "^4.0.0"
  }
}
```

`relay/wrangler.jsonc`:

```jsonc
{
  "name": "claude-status-relay",
  "main": "src/index.ts",
  "compatibility_date": "2026-07-10",
  "compatibility_flags": ["nodejs_compat"],
  "observability": { "enabled": true },
  "durable_objects": {
    "bindings": [{ "name": "RELAY", "class_name": "RelayDO" }]
  },
  "migrations": [{ "tag": "v1", "new_sqlite_classes": ["RelayDO"] }]
}
```

`relay/tsconfig.json`:

```jsonc
{
  "compilerOptions": {
    "target": "esnext",
    "module": "esnext",
    "moduleResolution": "bundler",
    "strict": true,
    "noEmit": true,
    "skipLibCheck": true,
    "types": ["@cloudflare/vitest-pool-workers/types"]
  },
  "include": ["src", "test", "worker-configuration.d.ts"]
}
```

`relay/vitest.config.ts` (the `miniflare.bindings` entry stands in for the `RELAY_TOKEN` secret during tests):

```ts
import { defineConfig } from "vitest/config";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: { bindings: { RELAY_TOKEN: "test-token" } },
    }),
  ],
});
```

`relay/.gitignore`:

```
node_modules/
.wrangler/
```

Stub `relay/src/relay-do.ts` (replaced in Task 2):

```ts
import { DurableObject } from "cloudflare:workers";

export class RelayDO extends DurableObject<Env> {
  async fetch(_request: Request): Promise<Response> {
    return new Response("not found", { status: 404 });
  }
}
```

Stub `relay/src/index.ts` (replaced in Task 3):

```ts
export { RelayDO } from "./relay-do";

export default {
  async fetch(_request, _env, _ctx): Promise<Response> {
    return new Response("not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
```

Run: `cd relay && npm install && npx wrangler types`
Expected: `worker-configuration.d.ts` generated declaring a global `Env` with `RELAY: DurableObjectNamespace` (commit this file). If `RELAY_TOKEN` is not in the generated `Env` (it's a secret, not a var), append it via a small declaration file `relay/src/env.d.ts`:

```ts
interface Env {
  RELAY_TOKEN: string;
}
```

(Interface merging adds the secret to the generated global `Env`; add `"src/env.d.ts"` is already inside `include: ["src", ...]`.)

- [ ] **Step 2: Write the failing classification tests**

`relay/test/classify.test.ts` — this table is the shell hook's behavior (`hooks/status-hook.sh` lines 41–57) transplanted server-side, plus expiry predicates:

```ts
import { describe, it, expect } from "vitest";
import {
  classify,
  repoName,
  cloudExpired,
  hostExpired,
  CLOUD_TTL_S,
  HOST_PRUNE_S,
} from "../src/classify";

describe("classify", () => {
  it("SessionStart → idle", () => {
    expect(classify({ hook_event_name: "SessionStart" })).toEqual({ kind: "set", state: "idle" });
  });

  it("UserPromptSubmit and PostToolUse → working", () => {
    expect(classify({ hook_event_name: "UserPromptSubmit" })).toEqual({ kind: "set", state: "working" });
    expect(classify({ hook_event_name: "PostToolUse", tool_name: "AskUserQuestion" })).toEqual({
      kind: "set",
      state: "working",
    });
  });

  it("PreToolUse → working, except AskUserQuestion → attention", () => {
    expect(classify({ hook_event_name: "PreToolUse", tool_name: "Bash" })).toEqual({ kind: "set", state: "working" });
    expect(classify({ hook_event_name: "PreToolUse", tool_name: "AskUserQuestion" })).toEqual({
      kind: "set",
      state: "attention",
    });
  });

  it("Notification → attention, except the ~60s idle reminder → idle", () => {
    expect(classify({ hook_event_name: "Notification", message: "Claude needs your permission to use Bash" })).toEqual(
      { kind: "set", state: "attention" },
    );
    expect(classify({ hook_event_name: "Notification", message: "Claude is waiting for your input" })).toEqual({
      kind: "set",
      state: "idle",
    });
  });

  it("Stop → idle, SessionEnd → delete", () => {
    expect(classify({ hook_event_name: "Stop" })).toEqual({ kind: "set", state: "idle" });
    expect(classify({ hook_event_name: "SessionEnd" })).toEqual({ kind: "delete" });
  });

  it("Subagent events adjust the count", () => {
    expect(classify({ hook_event_name: "SubagentStart" })).toEqual({ kind: "agents", delta: 1 });
    expect(classify({ hook_event_name: "SubagentStop" })).toEqual({ kind: "agents", delta: -1 });
  });

  it("unknown events are ignored", () => {
    expect(classify({ hook_event_name: "SomethingNew" })).toEqual({ kind: "ignore" });
    expect(classify({})).toEqual({ kind: "ignore" });
  });
});

describe("repoName", () => {
  it("takes the last path component", () => {
    expect(repoName("/home/user/work/my-repo")).toBe("my-repo");
    expect(repoName("/home/user/work/my-repo/")).toBe("my-repo");
  });

  it("returns null when there is nothing usable", () => {
    expect(repoName(undefined)).toBeNull();
    expect(repoName("")).toBeNull();
    expect(repoName("/")).toBeNull();
  });
});

describe("expiry", () => {
  it("cloud sessions expire after the TTL", () => {
    expect(cloudExpired(1000, 1000 + CLOUD_TTL_S)).toBe(false);
    expect(cloudExpired(1000, 1000 + CLOUD_TTL_S + 1)).toBe(true);
  });

  it("host records are pruned after a day", () => {
    expect(hostExpired(1000, 1000 + HOST_PRUNE_S)).toBe(false);
    expect(hostExpired(1000, 1000 + HOST_PRUNE_S + 1)).toBe(true);
  });
});
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `cd relay && npx vitest run test/classify.test.ts`
Expected: FAIL — cannot resolve `../src/classify`.

- [ ] **Step 4: Implement `relay/src/classify.ts`**

```ts
// Server-side twin of hooks/status-hook.sh's event classification: cloud
// sandboxes can't run the local hook pipeline, so raw hook payloads are
// POSTed and interpreted here. Keep the two in sync.

export type HookAction =
  | { kind: "set"; state: "idle" | "working" | "attention" }
  | { kind: "delete" }
  | { kind: "agents"; delta: 1 | -1 }
  | { kind: "ignore" };

export const CLOUD_TTL_S = 30 * 60;
export const HOST_PRUNE_S = 24 * 60 * 60;

export function classify(payload: Record<string, unknown>): HookAction {
  switch (payload.hook_event_name) {
    case "SessionStart":
      return { kind: "set", state: "idle" };
    case "UserPromptSubmit":
    case "PostToolUse":
      return { kind: "set", state: "working" };
    case "PreToolUse":
      // AskUserQuestion never fires a permission Notification; only the
      // Pre event may upgrade — Post means the question was just answered.
      return payload.tool_name === "AskUserQuestion"
        ? { kind: "set", state: "attention" }
        : { kind: "set", state: "working" };
    case "Notification": {
      // The ~60s reminder just means "ready for your next prompt".
      const message = String(payload.message ?? "").toLowerCase();
      return message.includes("waiting for your input")
        ? { kind: "set", state: "idle" }
        : { kind: "set", state: "attention" };
    }
    case "Stop":
      return { kind: "set", state: "idle" };
    case "SessionEnd":
      return { kind: "delete" };
    case "SubagentStart":
      return { kind: "agents", delta: 1 };
    case "SubagentStop":
      return { kind: "agents", delta: -1 };
    default:
      return { kind: "ignore" };
  }
}

export function repoName(cwd: unknown): string | null {
  const parts = String(cwd ?? "").split("/").filter(Boolean);
  return parts.length ? parts[parts.length - 1] : null;
}

export function cloudExpired(receivedAt: number, now: number): boolean {
  return now - receivedAt > CLOUD_TTL_S;
}

export function hostExpired(receivedAt: number, now: number): boolean {
  return now - receivedAt > HOST_PRUNE_S;
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd relay && npx vitest run test/classify.test.ts`
Expected: PASS (10 tests).

- [ ] **Step 6: Commit**

```bash
git add relay
git commit -m "Scaffold status relay Worker with server-side hook classification"
```

---

### Task 2: RelayDO — storage, endpoints, pruning

**Files:**
- Modify: `relay/src/relay-do.ts` (replace the stub)
- Test: `relay/test/relay-do.test.ts`

**Interfaces:**
- Consumes: `classify`, `repoName`, `cloudExpired`, `hostExpired` from `./classify`.
- Produces: `RelayDO` (Durable Object) handling, on its own fetch:
  - `POST /hosts/:name` body `{"sessions":[…]}` → stores `{name, received_at, sessions}` (snapshot-replace) → `{"ok":true}`
  - `POST /hook` body = raw hook payload → classified upsert/delete of `cloud:<session_id>` records → `{"ok":true}`
  - `GET /sessions` → `{"now":<s>,"hosts":[{name,received_at,sessions}],"cloud":[{session_id,state,repo,agents,received_at}]}` (expired entries pruned)
- Auth lives in the Worker (Task 3), **not** here.

- [ ] **Step 1: Write the failing DO tests**

`relay/test/relay-do.test.ts`. Fresh DO per test via a random name — no state bleed. If TypeScript flags `instance.ctx` as protected inside `runInDurableObject`, cast with `(instance as unknown as { ctx: DurableObjectState }).ctx` (test-only).

```ts
import { describe, it, expect } from "vitest";
import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { CLOUD_TTL_S } from "../src/classify";
import type { RelayDO } from "../src/relay-do";

function relay() {
  return env.RELAY.get(env.RELAY.idFromName(crypto.randomUUID()));
}

function post(stub: DurableObjectStub, path: string, body: unknown) {
  return stub.fetch(`https://relay${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
}

async function sessions(stub: DurableObjectStub) {
  const res = await stub.fetch("https://relay/sessions");
  expect(res.status).toBe(200);
  return (await res.json()) as {
    now: number;
    hosts: { name: string; received_at: number; sessions: unknown[] }[];
    cloud: { session_id: string; state: string; repo: string; agents: number; received_at: number }[];
  };
}

const wireSession = {
  session_id: "abc",
  state: "working",
  cwd: "/Users/luke/proj",
  term_program: "iTerm.app",
  tty: "/dev/ttys001",
  updated_at: 1_752_000_000,
  agents: 0,
  title: null,
  shells: [],
  background: false,
};

describe("host snapshots", () => {
  it("stores a snapshot and returns it with a received_at stamp", async () => {
    const stub = relay();
    const res = await post(stub, "/hosts/office-mini", { sessions: [wireSession] });
    expect(res.status).toBe(200);

    const body = await sessions(stub);
    expect(body.hosts).toHaveLength(1);
    expect(body.hosts[0].name).toBe("office-mini");
    expect(body.hosts[0].sessions).toEqual([wireSession]);
    expect(body.now - body.hosts[0].received_at).toBeLessThan(5);
  });

  it("replaces the previous snapshot wholesale", async () => {
    const stub = relay();
    await post(stub, "/hosts/office-mini", { sessions: [wireSession, { ...wireSession, session_id: "def" }] });
    await post(stub, "/hosts/office-mini", { sessions: [] });
    const body = await sessions(stub);
    expect(body.hosts[0].sessions).toEqual([]);
  });

  it("keeps hosts separate", async () => {
    const stub = relay();
    await post(stub, "/hosts/office-mini", { sessions: [wireSession] });
    await post(stub, "/hosts/studio", { sessions: [] });
    const body = await sessions(stub);
    expect(body.hosts.map((h) => h.name).sort()).toEqual(["office-mini", "studio"]);
  });

  it("rejects an empty host name", async () => {
    const res = await post(relay(), "/hosts/", { sessions: [] });
    expect(res.status).toBe(400);
  });
});

describe("cloud hook ingestion", () => {
  it("creates an idle session on SessionStart, labeled by repo", async () => {
    const stub = relay();
    await post(stub, "/hook", { hook_event_name: "SessionStart", session_id: "c1", cwd: "/work/my-repo" });
    const body = await sessions(stub);
    expect(body.cloud).toHaveLength(1);
    expect(body.cloud[0]).toMatchObject({ session_id: "c1", state: "idle", repo: "my-repo", agents: 0 });
  });

  it("tracks state transitions and preserves the repo label", async () => {
    const stub = relay();
    await post(stub, "/hook", { hook_event_name: "SessionStart", session_id: "c1", cwd: "/work/my-repo" });
    await post(stub, "/hook", { hook_event_name: "PreToolUse", tool_name: "AskUserQuestion", session_id: "c1" });
    let body = await sessions(stub);
    expect(body.cloud[0]).toMatchObject({ state: "attention", repo: "my-repo" });

    await post(stub, "/hook", { hook_event_name: "Stop", session_id: "c1" });
    body = await sessions(stub);
    expect(body.cloud[0].state).toBe("idle");
  });

  it("counts subagents, floors at zero, resets on SessionStart", async () => {
    const stub = relay();
    await post(stub, "/hook", { hook_event_name: "SessionStart", session_id: "c1", cwd: "/w/r" });
    await post(stub, "/hook", { hook_event_name: "SubagentStart", session_id: "c1" });
    await post(stub, "/hook", { hook_event_name: "SubagentStart", session_id: "c1" });
    await post(stub, "/hook", { hook_event_name: "SubagentStop", session_id: "c1" });
    let body = await sessions(stub);
    expect(body.cloud[0].agents).toBe(1);

    await post(stub, "/hook", { hook_event_name: "SubagentStop", session_id: "c1" });
    await post(stub, "/hook", { hook_event_name: "SubagentStop", session_id: "c1" });
    body = await sessions(stub);
    expect(body.cloud[0].agents).toBe(0);

    await post(stub, "/hook", { hook_event_name: "SubagentStart", session_id: "c1" });
    await post(stub, "/hook", { hook_event_name: "SessionStart", session_id: "c1", cwd: "/w/r" });
    body = await sessions(stub);
    expect(body.cloud[0].agents).toBe(0);
  });

  it("SessionEnd removes the session; agent events for unknown sessions are ignored", async () => {
    const stub = relay();
    await post(stub, "/hook", { hook_event_name: "SessionStart", session_id: "c1", cwd: "/w/r" });
    await post(stub, "/hook", { hook_event_name: "SessionEnd", session_id: "c1" });
    await post(stub, "/hook", { hook_event_name: "SubagentStart", session_id: "ghost" });
    const body = await sessions(stub);
    expect(body.cloud).toEqual([]);
  });

  it("ignores payloads without a session_id", async () => {
    const stub = relay();
    const res = await post(stub, "/hook", { hook_event_name: "Stop" });
    expect(res.status).toBe(200);
    expect((await sessions(stub)).cloud).toEqual([]);
  });
});

describe("pruning", () => {
  it("drops expired cloud sessions from the snapshot and from storage", async () => {
    const stub = relay();
    await post(stub, "/hook", { hook_event_name: "SessionStart", session_id: "old", cwd: "/w/r" });
    // Backdate the record past the TTL.
    await runInDurableObject(stub, async (instance: RelayDO) => {
      const record = await instance.ctx.storage.get<{ received_at: number }>("cloud:old");
      await instance.ctx.storage.put("cloud:old", {
        ...record!,
        received_at: record!.received_at - CLOUD_TTL_S - 10,
      });
    });
    const body = await sessions(stub);
    expect(body.cloud).toEqual([]);
    await runInDurableObject(stub, async (instance: RelayDO) => {
      expect(await instance.ctx.storage.get("cloud:old")).toBeUndefined();
    });
  });
});

describe("routing", () => {
  it("404s unknown paths", async () => {
    const res = await relay().fetch("https://relay/nope");
    expect(res.status).toBe(404);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd relay && npx vitest run test/relay-do.test.ts`
Expected: FAIL — the stub 404s everything (assertions on 200s fail).

- [ ] **Step 3: Implement `relay/src/relay-do.ts`**

```ts
import { DurableObject } from "cloudflare:workers";
import { classify, repoName, cloudExpired, hostExpired } from "./classify";

interface HostRecord {
  name: string;
  received_at: number;
  sessions: unknown[];
}

interface CloudRecord {
  session_id: string;
  state: "idle" | "working" | "attention";
  repo: string;
  agents: number;
  received_at: number;
}

/// Single-instance store for everything remote. Hosts push whole snapshots
/// (the snapshot doubles as the host's heartbeat); cloud sandboxes push raw
/// hook payloads that get classified here. All staleness math everywhere
/// uses this object's clock — client clocks are never trusted.
export class RelayDO extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const now = Math.floor(Date.now() / 1000);

    if (request.method === "POST" && url.pathname.startsWith("/hosts/")) {
      const name = decodeURIComponent(url.pathname.slice("/hosts/".length));
      if (!name) return new Response("missing host name", { status: 400 });
      const body = (await request.json().catch(() => ({}))) as { sessions?: unknown[] };
      const record: HostRecord = { name, received_at: now, sessions: body.sessions ?? [] };
      await this.ctx.storage.put(`host:${name}`, record);
      return Response.json({ ok: true });
    }

    if (request.method === "POST" && url.pathname === "/hook") {
      const payload = (await request.json().catch(() => ({}))) as Record<string, unknown>;
      await this.ingestHook(payload, now);
      return Response.json({ ok: true });
    }

    if (request.method === "GET" && url.pathname === "/sessions") {
      return Response.json(await this.snapshot(now));
    }

    return new Response("not found", { status: 404 });
  }

  private async ingestHook(payload: Record<string, unknown>, now: number): Promise<void> {
    const sessionId = String(payload.session_id ?? "");
    if (!sessionId) return;
    const key = `cloud:${sessionId}`;
    const action = classify(payload);
    const existing = await this.ctx.storage.get<CloudRecord>(key);

    switch (action.kind) {
      case "ignore":
        return;
      case "delete":
        await this.ctx.storage.delete(key);
        return;
      case "agents": {
        // Ignore counts for unknown sessions — a surprising payload must
        // not create ghost records (mirrors the local hook's guard).
        if (!existing) return;
        await this.ctx.storage.put(key, {
          ...existing,
          agents: Math.max(0, existing.agents + action.delta),
          received_at: now,
        });
        return;
      }
      case "set": {
        const isStart = payload.hook_event_name === "SessionStart";
        const record: CloudRecord = {
          session_id: sessionId,
          state: action.state,
          repo: repoName(payload.cwd) ?? existing?.repo ?? "cloud",
          // A fresh session cannot have running subagents.
          agents: isStart ? 0 : existing?.agents ?? 0,
          received_at: now,
        };
        await this.ctx.storage.put(key, record);
        return;
      }
    }
  }

  /// Everything current, pruning expired entries as a side effect so
  /// storage stays bounded without alarms.
  private async snapshot(now: number) {
    const hosts: HostRecord[] = [];
    const cloud: CloudRecord[] = [];
    for (const [key, value] of await this.ctx.storage.list()) {
      if (key.startsWith("host:")) {
        const host = value as HostRecord;
        if (hostExpired(host.received_at, now)) {
          await this.ctx.storage.delete(key);
          continue;
        }
        hosts.push(host);
      } else if (key.startsWith("cloud:")) {
        const record = value as CloudRecord;
        if (cloudExpired(record.received_at, now)) {
          await this.ctx.storage.delete(key);
          continue;
        }
        cloud.push(record);
      }
    }
    return { now, hosts, cloud };
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd relay && npx vitest run test/relay-do.test.ts`
Expected: PASS. Also run `npx tsc --noEmit` — clean.

- [ ] **Step 5: Commit**

```bash
git add relay/src/relay-do.ts relay/test/relay-do.test.ts
git commit -m "Store host snapshots and classified cloud sessions in RelayDO"
```

---

### Task 3: Worker entry — auth + routing to the DO

**Files:**
- Modify: `relay/src/index.ts` (replace the stub)
- Test: `relay/test/worker.test.ts`

**Interfaces:**
- Consumes: `RelayDO` from `./relay-do`; `Env` global (`RELAY`, `RELAY_TOKEN`).
- Produces: deployed HTTP surface — every route requires `Authorization: Bearer <RELAY_TOKEN>`; authorized requests are forwarded verbatim to the singleton DO (`idFromName("singleton")`). Clients in later tasks depend on exactly: `POST /hosts/:name`, `POST /hook`, `GET /sessions`, 401 on bad token.

- [ ] **Step 1: Write the failing integration tests**

`relay/test/worker.test.ts` — `exports.default.fetch(request)` invokes the deployed handler with bindings injected (current vitest-pool-workers integration style; if the signature differs, follow https://developers.cloudflare.com/workers/testing/vitest-integration/write-your-first-test/):

```ts
import { describe, it, expect } from "vitest";
import { exports } from "cloudflare:workers";

function request(path: string, init: RequestInit = {}, token?: string) {
  const headers = new Headers(init.headers);
  if (token !== undefined) headers.set("Authorization", `Bearer ${token}`);
  return new Request(`https://relay.example${path}`, { ...init, headers });
}

describe("auth", () => {
  it("rejects missing and wrong tokens", async () => {
    expect((await exports.default.fetch(request("/sessions"))).status).toBe(401);
    expect((await exports.default.fetch(request("/sessions", {}, "wrong"))).status).toBe(401);
  });

  it("accepts the configured token", async () => {
    const res = await exports.default.fetch(request("/sessions", {}, "test-token"));
    expect(res.status).toBe(200);
    const body = (await res.json()) as { now: number; hosts: unknown[]; cloud: unknown[] };
    expect(body.hosts).toEqual([]);
    expect(body.cloud).toEqual([]);
  });
});

describe("end to end through the worker", () => {
  it("a host snapshot posted through the worker shows up in GET /sessions", async () => {
    const post = await exports.default.fetch(
      request(
        "/hosts/office-mini",
        { method: "POST", body: JSON.stringify({ sessions: [] }) },
        "test-token",
      ),
    );
    expect(post.status).toBe(200);

    const res = await exports.default.fetch(request("/sessions", {}, "test-token"));
    const body = (await res.json()) as { hosts: { name: string }[] };
    expect(body.hosts.map((h) => h.name)).toContain("office-mini");
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd relay && npx vitest run test/worker.test.ts`
Expected: FAIL — stub returns 404 for everything (401/200 assertions fail).

- [ ] **Step 3: Implement `relay/src/index.ts`**

```ts
export { RelayDO } from "./relay-do";

/// Timing-safe bearer check: hash both sides so lengths always match, then
/// constant-time compare. Direct string comparison leaks via timing.
async function authorized(request: Request, env: Env): Promise<boolean> {
  const header = request.headers.get("Authorization") ?? "";
  const provided = header.replace(/^Bearer\s+/i, "");
  if (!provided || !env.RELAY_TOKEN) return false;
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(provided)),
    crypto.subtle.digest("SHA-256", encoder.encode(env.RELAY_TOKEN)),
  ]);
  return crypto.subtle.timingSafeEqual(a, b);
}

export default {
  async fetch(request, env, _ctx): Promise<Response> {
    if (!(await authorized(request, env))) {
      return new Response("unauthorized", { status: 401 });
    }
    // One DO holds all state: strong consistency, one clock for all
    // staleness math (KV's cross-edge lag would show stale lights).
    const stub = env.RELAY.get(env.RELAY.idFromName("singleton"));
    return stub.fetch(request);
  },
} satisfies ExportedHandler<Env>;
```

- [ ] **Step 4: Run the full relay suite**

Run: `cd relay && npx vitest run && npx tsc --noEmit`
Expected: all three test files PASS; tsc clean.

- [ ] **Step 5: Commit**

```bash
git add relay/src/index.ts relay/test/worker.test.ts
git commit -m "Gate the relay behind a timing-safe bearer token"
```

---

### Task 4: Cloud hook script + repo enabler

**Files:**
- Create: `hooks/status-relay.sh`
- Create: `scripts/enable-cloud-hooks.sh`
- Test: `Tests/relay_hook_test.sh`

**Interfaces:**
- Consumes: Worker route `POST /hook` (Task 3); env vars `CLAUDE_CODE_REMOTE`, `STATUS_LIGHT_RELAY_URL`, `STATUS_LIGHT_RELAY_TOKEN` (set in the Claude Code cloud environment config, never in the repo).
- Produces: `hooks/status-relay.sh` (template copied into target repos as `.claude/status-relay.sh`); `scripts/enable-cloud-hooks.sh <repo-path>` stamps the script + hook entries into a repo.

- [ ] **Step 1: Write the failing hook test**

`Tests/relay_hook_test.sh` (same style as `Tests/hook_test.sh`; a PATH-shimmed curl records invocations):

```bash
#!/bin/bash
# Tests for hooks/status-relay.sh — the cloud-side relay hook.
#
# The script must be inert outside cloud sandboxes (no CLAUDE_CODE_REMOTE),
# inert without relay env vars, and otherwise POST the raw hook payload to
# $STATUS_LIGHT_RELAY_URL/hook with the bearer token — in the background,
# always exiting 0 immediately.
set -euo pipefail
HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/status-relay.sh"
TMP="$(mktemp -d)"
export CURL_LOG="$TMP/curl.log"

cat > "$TMP/curl" <<'SH'
#!/bin/bash
{ echo "ARGS: $*"; cat; echo; } >> "${CURL_LOG:?}"
SH
chmod +x "$TMP/curl"
export PATH="$TMP:$PATH"

echo "--- inert without CLAUDE_CODE_REMOTE"
printf '{"session_id":"s1"}' | bash "$HOOK"
sleep 0.3
[ ! -e "$CURL_LOG" ] || { echo "FAIL: curl ran locally" >&2; exit 1; }

echo "--- inert without relay env vars"
printf '{"session_id":"s1"}' | CLAUDE_CODE_REMOTE=true bash "$HOOK"
sleep 0.3
[ ! -e "$CURL_LOG" ] || { echo "FAIL: curl ran without config" >&2; exit 1; }

echo "--- posts the payload when remote env is present"
export CLAUDE_CODE_REMOTE=true
export STATUS_LIGHT_RELAY_URL="https://relay.example"
export STATUS_LIGHT_RELAY_TOKEN="tok"
printf '{"session_id":"s1","hook_event_name":"Stop"}' | bash "$HOOK"
sleep 0.5  # the curl is backgrounded
grep -q 'https://relay.example/hook' "$CURL_LOG" || { echo "FAIL: missing url" >&2; exit 1; }
grep -q 'Bearer tok' "$CURL_LOG" || { echo "FAIL: missing token" >&2; exit 1; }
grep -q '"hook_event_name":"Stop"' "$CURL_LOG" || { echo "FAIL: missing payload" >&2; exit 1; }

echo "all ok"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash Tests/relay_hook_test.sh`
Expected: FAIL — `hooks/status-relay.sh: No such file or directory`.

- [ ] **Step 3: Implement `hooks/status-relay.sh`**

```bash
#!/bin/bash
# Claude Status Light cloud relay hook.
#
# Committed into a repo as .claude/status-relay.sh so Claude Code cloud
# sandboxes (claude.ai/code, desktop-app cloud sessions) can report their
# lifecycle events to the user's relay Worker. User-level settings never
# sync to cloud sandboxes, so this must live in the repo — but it is inert
# everywhere except a cloud sandbox, and carries no secrets: the relay URL
# and token come from env vars set in the Claude Code environment config.
#
# Must always exit 0 and never block — it runs inline in Claude Code.

[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0
[ -n "${STATUS_LIGHT_RELAY_URL:-}" ] || exit 0
[ -n "${STATUS_LIGHT_RELAY_TOKEN:-}" ] || exit 0

PAYLOAD="$(cat 2>/dev/null || true)"

printf '%s' "$PAYLOAD" | curl -s -m 2 -X POST "$STATUS_LIGHT_RELAY_URL/hook" \
    -H "Authorization: Bearer $STATUS_LIGHT_RELAY_TOKEN" \
    -H "Content-Type: application/json" \
    --data-binary @- >/dev/null 2>&1 &

exit 0
```

`chmod +x hooks/status-relay.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash Tests/relay_hook_test.sh`
Expected: `all ok`. Also re-run `bash Tests/hook_test.sh` — still passes (untouched, but cheap).

- [ ] **Step 5: Implement `scripts/enable-cloud-hooks.sh`**

```bash
#!/bin/bash
# Stamp the cloud relay hook into a repo so its cloud sessions report to
# the status light: copies hooks/status-relay.sh to <repo>/.claude/ and
# merges hook entries for every lifecycle event into the repo's committed
# .claude/settings.json. Idempotent — safe to re-run.
#
# Usage: scripts/enable-cloud-hooks.sh /path/to/repo
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="${1:?usage: enable-cloud-hooks.sh /path/to/repo}"
[ -d "$REPO" ] || { echo "no such directory: $REPO" >&2; exit 1; }

mkdir -p "$REPO/.claude"
cp "$HERE/hooks/status-relay.sh" "$REPO/.claude/status-relay.sh"
chmod +x "$REPO/.claude/status-relay.sh"

python3 - "$REPO/.claude/settings.json" <<'PY'
import json, os, sys

path = sys.argv[1]
settings = {}
if os.path.exists(path):
    with open(path) as f:
        settings = json.load(f)

COMMAND = '"$CLAUDE_PROJECT_DIR"/.claude/status-relay.sh'
EVENTS = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
          "Notification", "Stop", "SessionEnd", "SubagentStart", "SubagentStop"]

hooks = settings.setdefault("hooks", {})
for event in EVENTS:
    entries = hooks.setdefault(event, [])
    already = any(
        h.get("command") == COMMAND
        for entry in entries for h in entry.get("hooks", [])
    )
    if not already:
        entries.append({"hooks": [{"type": "command", "command": COMMAND}]})

with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
print(f"cloud relay hooks enabled in {path}")
PY

echo "Remember (once per Claude Code cloud environment):"
echo "  1. set env vars STATUS_LIGHT_RELAY_URL and STATUS_LIGHT_RELAY_TOKEN"
echo "  2. add your Worker's domain to the environment's network allowlist"
echo "Then commit $REPO/.claude/ so cloud sandboxes pick it up."
```

`chmod +x scripts/enable-cloud-hooks.sh`

- [ ] **Step 6: Smoke-test the enabler**

Run:

```bash
TMPREPO=$(mktemp -d) && scripts/enable-cloud-hooks.sh "$TMPREPO" && scripts/enable-cloud-hooks.sh "$TMPREPO" \
  && python3 -c "import json;s=json.load(open('$TMPREPO/.claude/settings.json'));assert len(s['hooks']['Stop'])==1;print('idempotent ok')"
```

Expected: `idempotent ok` (running twice does not duplicate entries) and `.claude/status-relay.sh` exists in `$TMPREPO`.

- [ ] **Step 7: Commit**

```bash
git add hooks/status-relay.sh scripts/enable-cloud-hooks.sh Tests/relay_hook_test.sh
git commit -m "Add cloud relay hook and per-repo enabler"
```

---

### Task 5: SessionState grows origin + background override

**Files:**
- Modify: `Sources/ClaudeStatusLight/Model.swift`
- Test: `Tests/ClaudeStatusLightTests/SessionLabelTests.swift` (append tests)

**Interfaces:**
- Consumes: existing `SessionState`.
- Produces: `SessionState.origin: String?` (nil = local; else host label or `"cloud"`), `SessionState.backgroundOverride: Bool?` — both `var … = nil`, declared **after** `shells` so every existing memberwise call site still compiles. `isBackground` becomes `backgroundOverride ?? (pid != nil && tty.isEmpty)`. `displayName` gains an origin prefix; `tooltip` gains an origin line. Later tasks construct remote sessions with these two fields.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ClaudeStatusLightTests/SessionLabelTests.swift` (match its existing helper style — read the file first; if its builder differs, adapt these to it):

```swift
// MARK: - Remote sessions

extension SessionLabelTests {
    private func remoteSession(
        origin: String? = "office-mini",
        state: LightState = .working,
        cwd: String = "/Users/luke/mlb-props",
        title: String? = nil,
        background: Bool? = true,
        age: TimeInterval = 0
    ) -> SessionState {
        SessionState(
            sessionID: "r1", state: state, cwd: cwd, termProgram: "remote",
            tty: "", pid: nil, updatedAt: Date().addingTimeInterval(-age),
            agents: 0, title: title, shells: [],
            origin: origin, backgroundOverride: background
        )
    }

    @Test func originPrefixesDisplayName() {
        #expect(remoteSession(title: "Improve win rate").displayName
            == "office-mini · mlb-props · Improve win rate")
        #expect(remoteSession(origin: "cloud", cwd: "my-repo", background: true).displayName
            == "cloud · my-repo (bg)")
    }

    @Test func localSessionsAreUnchanged() {
        let local = SessionState(
            sessionID: "l1", state: .idle, cwd: "/tmp/proj", termProgram: "iTerm.app",
            tty: "/dev/ttys001", pid: 1, updatedAt: Date(), agents: 0, title: nil, shells: []
        )
        #expect(local.origin == nil)
        #expect(local.displayName == "proj")
        #expect(local.isBackground == false)
    }

    @Test func backgroundOverrideBeatsPidHeuristic() {
        // Remote sessions have no meaningful pid; the publisher's verdict wins.
        #expect(remoteSession(background: true).isBackground == true)
        #expect(remoteSession(background: false).isBackground == false)
    }

    @Test func remoteBackgroundSessionsCanPark() {
        #expect(remoteSession(state: .idle, background: true, age: 3 * 60).isParked == true)
        #expect(remoteSession(state: .idle, background: false, age: 3 * 60).isParked == false)
    }

    @Test func tooltipNamesTheOrigin() {
        #expect(remoteSession().tooltip.contains("remote session on office-mini"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh`
Expected: FAIL — `SessionState` has no `origin`/`backgroundOverride` parameters.

- [ ] **Step 3: Implement the Model changes**

In `Sources/ClaudeStatusLight/Model.swift`, after `let shells: [String]` add:

```swift
    /// Where this session lives: nil = this Mac, else a publisher's host
    /// label or "cloud". Remote sessions can't be PID-checked or focused.
    var origin: String? = nil

    /// Remote sessions carry the publisher's background verdict — their
    /// recorded pid/tty are meaningless on this machine.
    var backgroundOverride: Bool? = nil
```

Change `isBackground`:

```swift
    var isBackground: Bool { backgroundOverride ?? (pid != nil && tty.isEmpty) }
```

Change `displayName` to prefix the origin (keep the existing body as the unprefixed base):

```swift
    var displayName: String {
        let base: String
        if !isBackground {
            base = project
        } else if var title, !title.isEmpty {
            if title.count > 48 {
                title = title.prefix(47) + "…"
            }
            base = "\(project) · \(title)"
        } else {
            base = "\(project) (bg)"
        }
        guard let origin else { return base }
        return "\(origin) · \(base)"
    }
```

In `tooltip`, replace the `isBackground` line so remote wins:

```swift
        if let origin {
            lines.append("remote session on \(origin)")
        } else if isParked {
            let minutes = Int(Date().timeIntervalSince(updatedAt) / 60)
            lines.append("parked — idle \(minutes)m, process alive")
        } else if isBackground {
            lines.append("background session (no terminal)")
        }
```

(Note: `isParked` still works for remote rows in the row-dimming path; only the tooltip prefers the origin line.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh`
Expected: PASS — new tests and the entire existing suite (no regressions from the `displayName` restructure).

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusLight/Model.swift Tests/ClaudeStatusLightTests/SessionLabelTests.swift
git commit -m "Give SessionState an origin and a background override for remote rows"
```

---

### Task 6: Wire format — Swift structs + conversions

**Files:**
- Create: `Sources/ClaudeStatusLight/RemoteWire.swift`
- Test: `Tests/ClaudeStatusLightTests/RemoteWireTests.swift`

**Interfaces:**
- Consumes: `SessionState` (+ Task 5 fields), `LightState`.
- Produces (all `Codable`, snake_case keys via `CodingKeys`, times epoch seconds):
  - `WireSession` — fields `sessionID/state/cwd/termProgram/tty/updatedAt/agents/title/shells/background`; `init(from: SessionState)`; `func sessionState(origin: String) -> SessionState?` (nil on unknown `state`)
  - `WireHost` — `name`, `receivedAt`, `sessions: [WireSession]`
  - `WireCloudSession` — `sessionID/state/repo/agents/receivedAt`; `func sessionState() -> SessionState?` (origin `"cloud"`, background true)
  - `WireSnapshot` — `now: Double`, `hosts: [WireHost]`, `cloud: [WireCloudSession]`
- These key names must match Task 2's DO JSON exactly (`session_id`, `term_program`, `updated_at`, `received_at`).

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeStatusLightTests/RemoteWireTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeStatusLight

struct RemoteWireTests {
    @Test func wireSessionRoundTripsFromSessionState() throws {
        let local = SessionState(
            sessionID: "abc", state: .working, cwd: "/Users/luke/proj",
            termProgram: "iTerm.app", tty: "/dev/ttys001", pid: 42,
            updatedAt: Date(timeIntervalSince1970: 1_752_000_000),
            agents: 2, title: "Improve win rate", shells: ["uv run train.py"]
        )
        let wire = WireSession(from: local)
        let data = try JSONEncoder().encode(wire)
        let decoded = try JSONDecoder().decode(WireSession.self, from: data)
        let remote = try #require(decoded.sessionState(origin: "office-mini"))

        #expect(remote.sessionID == "abc")
        #expect(remote.state == .working)
        #expect(remote.origin == "office-mini")
        #expect(remote.pid == nil)
        #expect(remote.updatedAt == Date(timeIntervalSince1970: 1_752_000_000))
        #expect(remote.agents == 2)
        #expect(remote.title == "Improve win rate")
        #expect(remote.shells == ["uv run train.py"])
        #expect(remote.backgroundOverride == false)  // local had a tty
    }

    @Test func wireUsesSnakeCaseKeys() throws {
        let local = SessionState(
            sessionID: "abc", state: .idle, cwd: "/p", termProgram: "t", tty: "",
            pid: 42, updatedAt: Date(timeIntervalSince1970: 1), agents: 0,
            title: nil, shells: []
        )
        let json = String(decoding: try JSONEncoder().encode(WireSession(from: local)), as: UTF8.self)
        #expect(json.contains("\"session_id\""))
        #expect(json.contains("\"term_program\""))
        #expect(json.contains("\"updated_at\""))
        #expect(json.contains("\"background\":true"))  // pid + empty tty = background
    }

    @Test func unknownStateIsDropped() throws {
        let json = #"{"session_id":"x","state":"levitating","cwd":"/p","term_program":"t","tty":"","updated_at":1,"agents":0,"title":null,"shells":[],"background":false}"#
        let wire = try JSONDecoder().decode(WireSession.self, from: Data(json.utf8))
        #expect(wire.sessionState(origin: "h") == nil)
    }

    @Test func snapshotDecodesTheRelayShape() throws {
        let json = #"""
        {"now":1752000100,
         "hosts":[{"name":"office-mini","received_at":1752000090,
                   "sessions":[{"session_id":"abc","state":"idle","cwd":"/p","term_program":"t","tty":"","updated_at":1752000000,"agents":0,"title":null,"shells":[],"background":true}]}],
         "cloud":[{"session_id":"c1","state":"attention","repo":"my-repo","agents":1,"received_at":1752000095}]}
        """#
        let snapshot = try JSONDecoder().decode(WireSnapshot.self, from: Data(json.utf8))
        #expect(snapshot.now == 1_752_000_100)
        #expect(snapshot.hosts.first?.name == "office-mini")
        #expect(snapshot.hosts.first?.sessions.first?.sessionID == "abc")

        let cloud = try #require(snapshot.cloud.first?.sessionState())
        #expect(cloud.origin == "cloud")
        #expect(cloud.state == .attention)
        #expect(cloud.project == "my-repo")   // repo string flows through cwd
        #expect(cloud.backgroundOverride == true)
        #expect(cloud.agents == 1)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh`
Expected: FAIL — no `WireSession` in scope.

- [ ] **Step 3: Implement `Sources/ClaudeStatusLight/RemoteWire.swift`**

```swift
import Foundation

/// Wire format shared with the relay Worker (relay/src/relay-do.ts) and the
/// publisher. Times are epoch seconds. Keys are snake_case to match the
/// hook-file format the rest of the pipeline already speaks.
struct WireSession: Codable, Equatable {
    var sessionID: String
    var state: String
    var cwd: String
    var termProgram: String
    var tty: String
    var updatedAt: Double
    var agents: Int
    var title: String?
    var shells: [String]
    var background: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state, cwd
        case termProgram = "term_program"
        case tty
        case updatedAt = "updated_at"
        case agents, title, shells, background
    }
}

// Conversions live in an extension so the struct keeps its synthesized
// memberwise init (an init declared in the main body would suppress it,
// and tests build WireSession values directly).
extension WireSession {
    /// Publisher side: capture the locally derived truth, including the
    /// background verdict — the receiver can't recompute it without a pid.
    init(from session: SessionState) {
        sessionID = session.sessionID
        state = session.state.rawValue
        cwd = session.cwd
        termProgram = session.termProgram
        tty = session.tty
        updatedAt = session.updatedAt.timeIntervalSince1970
        agents = session.agents
        title = session.title
        shells = session.shells
        background = session.isBackground
    }

    /// App side: a remote session never carries a pid (liveness is the
    /// host's heartbeat, not a local process). Unknown states are dropped
    /// rather than guessed.
    func sessionState(origin: String) -> SessionState? {
        guard let light = LightState(rawValue: state) else { return nil }
        return SessionState(
            sessionID: sessionID, state: light, cwd: cwd,
            termProgram: termProgram, tty: tty, pid: nil,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            agents: agents, title: title, shells: shells,
            origin: origin, backgroundOverride: background
        )
    }
}

struct WireHost: Codable {
    var name: String
    var receivedAt: Double
    var sessions: [WireSession]

    enum CodingKeys: String, CodingKey {
        case name
        case receivedAt = "received_at"
        case sessions
    }
}

struct WireCloudSession: Codable {
    var sessionID: String
    var state: String
    var repo: String
    var agents: Int
    var receivedAt: Double

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case state, repo, agents
        case receivedAt = "received_at"
    }

    /// Cloud sessions have no terminal and no transcript on this machine:
    /// repo name stands in for cwd (display uses its last path component,
    /// so a bare name flows through), updated = when the relay last heard.
    func sessionState() -> SessionState? {
        guard let light = LightState(rawValue: state) else { return nil }
        return SessionState(
            sessionID: sessionID, state: light, cwd: repo,
            termProgram: "cloud", tty: "", pid: nil,
            updatedAt: Date(timeIntervalSince1970: receivedAt),
            agents: agents, title: nil, shells: [],
            origin: "cloud", backgroundOverride: true
        )
    }
}

struct WireSnapshot: Codable {
    var now: Double
    var hosts: [WireHost]
    var cloud: [WireCloudSession]
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ClaudeStatusLight/RemoteWire.swift Tests/ClaudeStatusLightTests/RemoteWireTests.swift
git commit -m "Add the relay wire format with SessionState conversions"
```

---

### Task 7: RelayConfig + RemoteStore

**Files:**
- Create: `Sources/ClaudeStatusLight/RelayConfig.swift`
- Create: `Sources/ClaudeStatusLight/RemoteStore.swift`
- Test: `Tests/ClaudeStatusLightTests/RemoteStoreTests.swift`

**Interfaces:**
- Consumes: `WireSnapshot` etc. (Task 6).
- Produces:
  - `RelayConfig { url: URL; token: String; host: String; static func load(from: URL) -> RelayConfig? }` — default path `~/.claude/status-light/relay.json`, format `{"url":"https://…","token":"…","host":"office-mini"}` (`host` optional → local hostname).
  - `RemoteStore { init(config: RelayConfig?); var isConfigured: Bool; var unreachable: Bool; func start(); func sessions() -> [SessionState] }` — polls every 4 s, cache honored for 60 s after the last success.
  - `RemoteStore.sessions(from: WireSnapshot) -> [SessionState]` (static, pure — all staleness inside uses `snapshot.now`).
  - `RemoteStore.merge(local: [SessionState], remote: [SessionState]) -> [SessionState]` (static, pure — concat, sorted by `updatedAt` descending, matching `StateStore`'s ordering).

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeStatusLightTests/RemoteStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeStatusLight

struct RemoteStoreTests {
    private func wire(
        id: String = "s1", state: String = "working", updatedAt: Double = 1_000
    ) -> WireSession {
        WireSession(
            sessionID: id, state: state, cwd: "/p/proj", termProgram: "iTerm.app",
            tty: "", updatedAt: updatedAt, agents: 0, title: nil, shells: [], background: false
        )
    }

    private func snapshot(
        now: Double = 10_000,
        hosts: [WireHost] = [],
        cloud: [WireCloudSession] = []
    ) -> WireSnapshot {
        WireSnapshot(now: now, hosts: hosts, cloud: cloud)
    }

    @Test func freshHostSessionsComeThroughWithOrigin() {
        let snap = snapshot(hosts: [WireHost(name: "mini", receivedAt: 9_990, sessions: [wire()])])
        let sessions = RemoteStore.sessions(from: snap)
        #expect(sessions.count == 1)
        #expect(sessions.first?.origin == "mini")
    }

    @Test func staleHostIsDroppedEntirely() {
        // 61s since the host's last snapshot — past the 60s window.
        let snap = snapshot(hosts: [WireHost(name: "mini", receivedAt: 10_000 - 61, sessions: [wire()])])
        #expect(RemoteStore.sessions(from: snap).isEmpty)
    }

    @Test func expiredCloudSessionIsDropped() {
        let fresh = WireCloudSession(sessionID: "c1", state: "idle", repo: "r", agents: 0, receivedAt: 9_000)
        let stale = WireCloudSession(sessionID: "c2", state: "idle", repo: "r", agents: 0, receivedAt: 10_000 - 1_801)
        let sessions = RemoteStore.sessions(from: snapshot(cloud: [fresh, stale]))
        #expect(sessions.map(\.sessionID) == ["c1"])
    }

    @Test func unknownStatesAreDroppedNotGuessed() {
        let snap = snapshot(hosts: [WireHost(name: "mini", receivedAt: 9_990, sessions: [wire(state: "levitating")])])
        #expect(RemoteStore.sessions(from: snap).isEmpty)
    }

    @Test func mergeSortsByRecency() {
        let older = wire(id: "old", updatedAt: 1_000).sessionState(origin: "mini")!
        let newer = wire(id: "new", updatedAt: 2_000).sessionState(origin: "mini")!
        let local = SessionState(
            sessionID: "local", state: .idle, cwd: "/p", termProgram: "t", tty: "",
            pid: 1, updatedAt: Date(timeIntervalSince1970: 1_500), agents: 0, title: nil, shells: []
        )
        let merged = RemoteStore.merge(local: [local], remote: [older, newer])
        #expect(merged.map(\.sessionID) == ["new", "local", "old"])
    }

    @Test func unconfiguredStoreIsInertAndReachable() {
        let store = RemoteStore(config: nil)
        #expect(store.isConfigured == false)
        #expect(store.unreachable == false)
        #expect(store.sessions().isEmpty)
    }

    @Test func relayConfigLoads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("relay.json")
        try Data(#"{"url":"https://relay.example.workers.dev","token":"tok","host":"mini"}"#.utf8)
            .write(to: file)

        let config = try #require(RelayConfig.load(from: file))
        #expect(config.url.absoluteString == "https://relay.example.workers.dev")
        #expect(config.token == "tok")
        #expect(config.host == "mini")
        #expect(RelayConfig.load(from: dir.appendingPathComponent("missing.json")) == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh`
Expected: FAIL — no `RemoteStore`/`RelayConfig`.

- [ ] **Step 3: Implement `Sources/ClaudeStatusLight/RelayConfig.swift`**

```swift
import Foundation

/// Connection details for the relay Worker, written by scripts/deploy-relay.sh
/// to ~/.claude/status-light/relay.json (chmod 600). Absent file = the whole
/// remote-sessions feature is off.
struct RelayConfig: Equatable {
    let url: URL
    let token: String
    let host: String

    static let defaultPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/status-light/relay.json")

    static func load(from file: URL = defaultPath) -> RelayConfig? {
        guard
            let data = try? Data(contentsOf: file),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let urlString = obj["url"] as? String,
            let url = URL(string: urlString),
            let token = obj["token"] as? String, !token.isEmpty
        else { return nil }
        let host = (obj["host"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? ProcessInfo.processInfo.hostName
        return RelayConfig(url: url, token: token, host: host)
    }
}
```

- [ ] **Step 4: Implement `Sources/ClaudeStatusLight/RemoteStore.swift`**

```swift
import Foundation

/// Polls the relay Worker for sessions on other machines and in cloud
/// sandboxes. All within-snapshot staleness math uses the snapshot's own
/// `now` (the relay's clock); the local clock only decides whether our
/// cached snapshot itself is too old to trust.
final class RemoteStore {
    /// Host rows drop when their machine hasn't snapshotted for this long.
    static let hostStaleAfter: Double = 60
    /// Cloud rows drop when the relay hasn't heard an event for this long
    /// (mirrors the DO's own TTL — the app filter covers the lazy prune).
    static let cloudStaleAfter: Double = 30 * 60
    /// How often to poll, and how long a cached snapshot stays valid.
    static let pollInterval: TimeInterval = 4
    static let cacheValidFor: TimeInterval = 60

    private let config: RelayConfig?
    private let urlSession: URLSession
    private var timer: Timer?

    // Main-thread state (poll completions hop to main before touching it).
    private var latest: WireSnapshot?
    private var lastSuccess: Date?
    private var lastAttempt: Date?

    var isConfigured: Bool { config != nil }

    /// True once a poll has failed and nothing succeeded within the cache
    /// window — distinguishes "no remote sessions" from "can't see remote".
    var unreachable: Bool {
        guard isConfigured, lastAttempt != nil else { return false }
        guard let lastSuccess else { return true }
        return Date().timeIntervalSince(lastSuccess) > Self.cacheValidFor
    }

    init(config: RelayConfig?, urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    func start() {
        guard let config else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.poll(config: config)
        }
        timer.tolerance = 1
        self.timer = timer
        poll(config: config)
    }

    func sessions() -> [SessionState] {
        guard let latest, let lastSuccess,
              Date().timeIntervalSince(lastSuccess) <= Self.cacheValidFor
        else { return [] }
        return Self.sessions(from: latest)
    }

    /// Pure: wire snapshot → display sessions, staleness on the relay clock.
    static func sessions(from snapshot: WireSnapshot) -> [SessionState] {
        var result: [SessionState] = []
        for host in snapshot.hosts where snapshot.now - host.receivedAt <= hostStaleAfter {
            result.append(contentsOf: host.sessions.compactMap { $0.sessionState(origin: host.name) })
        }
        result.append(contentsOf: snapshot.cloud
            .filter { snapshot.now - $0.receivedAt <= cloudStaleAfter }
            .compactMap { $0.sessionState() })
        return result
    }

    /// Pure: one list for every surface, most recent first (the order
    /// StateStore already uses).
    static func merge(local: [SessionState], remote: [SessionState]) -> [SessionState] {
        (local + remote).sorted { $0.updatedAt > $1.updatedAt }
    }

    private func poll(config: RelayConfig) {
        lastAttempt = Date()
        var request = URLRequest(url: config.url.appendingPathComponent("sessions"))
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = Self.pollInterval

        urlSession.dataTask(with: request) { [weak self] data, response, _ in
            guard
                let data,
                (response as? HTTPURLResponse)?.statusCode == 200,
                let snapshot = try? JSONDecoder().decode(WireSnapshot.self, from: data)
            else { return }  // failure: cache ages out on its own
            DispatchQueue.main.async {
                self?.latest = snapshot
                self?.lastSuccess = Date()
            }
        }.resume()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusLight/RelayConfig.swift Sources/ClaudeStatusLight/RemoteStore.swift Tests/ClaudeStatusLightTests/RemoteStoreTests.swift
git commit -m "Poll the relay and convert remote snapshots into sessions"
```

---

### Task 8: Publisher mode

**Files:**
- Create: `Sources/ClaudeStatusLight/Publisher.swift`
- Modify: `Sources/ClaudeStatusLight/main.swift`
- Test: `Tests/ClaudeStatusLightTests/PublisherTests.swift`

**Interfaces:**
- Consumes: `StateStore.activeSessions()`, `WireSession`, `RelayConfig`.
- Produces: `Publisher.encodeSnapshot(_ sessions: [SessionState]) -> Data?` (deterministic: sessions sorted by `sessionID`, `.sortedKeys`) · `Publisher.shouldPush(payload: Data, lastPayload: Data?, lastPush: Date, now: Date) -> Bool` · `Publisher.run(config: RelayConfig) -> Never` · `claude-status-light --publish` CLI entry (exit 1 + stderr message when `relay.json` is missing).

- [ ] **Step 1: Write the failing tests**

`Tests/ClaudeStatusLightTests/PublisherTests.swift`:

```swift
import Foundation
import Testing
@testable import ClaudeStatusLight

struct PublisherTests {
    private func session(id: String, updatedAt: Double = 1_000) -> SessionState {
        SessionState(
            sessionID: id, state: .idle, cwd: "/p", termProgram: "t", tty: "",
            pid: 1, updatedAt: Date(timeIntervalSince1970: updatedAt),
            agents: 0, title: nil, shells: []
        )
    }

    @Test func snapshotEncodingIsDeterministic() throws {
        // Same sessions, either order → byte-identical payloads, so change
        // detection can compare Data directly.
        let a = try #require(Publisher.encodeSnapshot([session(id: "a"), session(id: "b")]))
        let b = try #require(Publisher.encodeSnapshot([session(id: "b"), session(id: "a")]))
        #expect(a == b)

        let obj = try JSONSerialization.jsonObject(with: a) as? [String: Any]
        let sessions = obj?["sessions"] as? [[String: Any]]
        #expect(sessions?.count == 2)
        #expect(sessions?.first?["session_id"] as? String == "a")
    }

    @Test func pushesOnChangeOrHeartbeat() {
        let payload = Data("new".utf8)
        let old = Data("old".utf8)
        let now = Date(timeIntervalSince1970: 10_000)

        // First run: nothing pushed yet.
        #expect(Publisher.shouldPush(payload: payload, lastPayload: nil, lastPush: .distantPast, now: now))
        // Changed content pushes immediately.
        #expect(Publisher.shouldPush(payload: payload, lastPayload: old, lastPush: now, now: now))
        // Unchanged content within the heartbeat window stays quiet.
        #expect(!Publisher.shouldPush(payload: payload, lastPayload: payload,
                                      lastPush: now.addingTimeInterval(-14), now: now))
        // Unchanged content past 15s heartbeats anyway (it is the liveness signal).
        #expect(Publisher.shouldPush(payload: payload, lastPayload: payload,
                                     lastPush: now.addingTimeInterval(-15), now: now))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test.sh`
Expected: FAIL — no `Publisher`.

- [ ] **Step 3: Implement `Sources/ClaudeStatusLight/Publisher.swift`**

```swift
import Foundation

/// Headless `--publish` mode: runs on a remote Mac (launchd agent) and
/// mirrors that machine's locally derived sessions — PID-checked, shells
/// scanned, titles read — up to the relay. Pushes on change, and at least
/// every 15s: the snapshot is also the host's heartbeat, so the app can
/// drop this host's rows when the pushes stop.
enum Publisher {
    static let heartbeat: TimeInterval = 15
    static let tick: TimeInterval = 2

    /// {"sessions":[…]} — sorted sessions + sorted keys so identical state
    /// yields identical bytes (change detection is a Data compare).
    static func encodeSnapshot(_ sessions: [SessionState]) -> Data? {
        let wire = sessions.map(WireSession.init(from:)).sorted { $0.sessionID < $1.sessionID }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(["sessions": wire])
    }

    static func shouldPush(payload: Data, lastPayload: Data?, lastPush: Date, now: Date) -> Bool {
        payload != lastPayload || now.timeIntervalSince(lastPush) >= heartbeat
    }

    static func run(config: RelayConfig) -> Never {
        let store = StateStore()
        var lastPayload: Data?
        var lastPush = Date.distantPast

        while true {
            let now = Date()
            if let payload = encodeSnapshot(store.activeSessions()),
               shouldPush(payload: payload, lastPayload: lastPayload, lastPush: lastPush, now: now),
               push(payload, config: config) {
                lastPayload = payload
                lastPush = now
            }
            // Failures fall through quietly: the next tick retries, and the
            // app drops this host's rows if silence exceeds its window.
            Thread.sleep(forTimeInterval: tick)
        }
    }

    private static func push(_ body: Data, config: RelayConfig) -> Bool {
        let encodedHost = config.host.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? config.host
        guard let url = URL(string: "hosts/\(encodedHost)", relativeTo: config.url) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var ok = false
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            ok = (response as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 15)
        return ok
    }
}
```

Note: `URL(string:relativeTo:)` against `https://x.workers.dev` yields `https://x.workers.dev/hosts/<host>`; if `config.url` ever carries a path, deployment docs say to use the bare Worker URL.

- [ ] **Step 4: Wire up `--publish` in `Sources/ClaudeStatusLight/main.swift`**

Insert between the `--render-iconset` block and `NSApplication.shared`:

```swift
// Headless publisher mode: mirror this machine's sessions to the relay.
// No NSApplication — runs fine from launchd with no UI.
if arguments.contains("--publish") {
    guard let config = RelayConfig.load() else {
        FileHandle.standardError.write(Data(
            "claude-status-light --publish: no \(RelayConfig.defaultPath.path); run scripts/deploy-relay.sh first\n".utf8))
        exit(1)
    }
    Publisher.run(config: config)
}
```

- [ ] **Step 5: Run tests + a manual smoke**

Run: `./scripts/test.sh`
Expected: PASS.

Run: `swift build && .build/debug/ClaudeStatusLight --publish; echo "exit: $?"`
Expected (no relay.json on this machine yet): the stderr message and `exit: 1`.

- [ ] **Step 6: Commit**

```bash
git add Sources/ClaudeStatusLight/Publisher.swift Sources/ClaudeStatusLight/main.swift Tests/ClaudeStatusLightTests/PublisherTests.swift
git commit -m "Add headless --publish mode that mirrors local sessions to the relay"
```

---

### Task 9: App-side merge, disabled remote rows, relay footer

**Files:**
- Modify: `Sources/ClaudeStatusLight/AppDelegate.swift`

**Interfaces:**
- Consumes: `RemoteStore` (Task 7), `RelayConfig.load()`, `SessionState.origin`.
- Produces: merged session lists on every surface; remote menu rows disabled (tooltip only); `relay unreachable` footer; floating-panel focus no-ops for remote rows.

- [ ] **Step 1: Merge remote sessions into refresh**

In `AppDelegate`, add the store next to the existing ones:

```swift
    private let remote = RemoteStore(config: RelayConfig.load())
```

In `applicationDidFinishLaunching`, guard the focus callback and start polling (replace the existing `floating.onFocus` line):

```swift
        floating.onFocus = { session in
            guard session.origin == nil else { return }  // nothing to focus locally
            TerminalFocuser.focus(session)
        }
        remote.start()
```

In `refresh()`, replace the first line:

```swift
        let sessions = RemoteStore.merge(local: store.activeSessions(), remote: remote.sessions())
```

- [ ] **Step 2: Disabled remote rows + footer in `makeMenu()`**

Replace the session-row loop body so remote rows get no action (NSMenu auto-disables action-less items, like the existing header), keeping tooltip and parked dimming:

```swift
            for session in currentSessions {
                let title = "\(session.state.dot) \(session.displayName)\(session.shellsSuffix) — \(session.state.label)\(session.agentsSuffix)"
                let item: NSMenuItem
                if session.origin == nil {
                    item = NSMenuItem(title: title, action: #selector(ClosureInvoker.fire), keyEquivalent: "")
                    let invoker = ClosureInvoker { TerminalFocuser.focus(session) }
                    item.target = invoker
                    item.representedObject = invoker // retain
                } else {
                    // Remote session — no terminal on this machine to focus.
                    item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                }
                if session.isParked {
                    item.attributedTitle = NSAttributedString(
                        string: item.title,
                        attributes: [
                            .foregroundColor: NSColor.secondaryLabelColor,
                            .font: NSFont.menuFont(ofSize: 0),
                        ])
                }
                item.toolTip = session.tooltip
                menu.addItem(item)
            }
```

After the sessions block (before the trailing `menu.addItem(.separator())`), add the footer:

```swift
        // Absence of remote rows must be distinguishable from a dead relay.
        if remote.isConfigured && remote.unreachable {
            menu.addItem(.separator())
            let item = NSMenuItem(title: "relay unreachable", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
```

Also update the hint line so it's only shown when there is something clickable:

```swift
        if currentSessions.contains(where: { $0.origin == nil }) {
            let hint = NSMenuItem(title: "Click a session to open its terminal", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            menu.addItem(hint)
        }
```

(Keep the surrounding `if !currentSessions.isEmpty { menu.addItem(.separator()); … }` structure — only the hint becomes conditional on a local row existing.)

- [ ] **Step 3: Build, test, and verify by hand**

Run: `./scripts/test.sh && swift build`
Expected: PASS / clean build (this task is AppKit glue over already-tested pure functions — `merge`, `sessions(from:)`, `unreachable` — so no new unit tests; the `verify` skill covers it end-to-end).

Manual check with a fake snapshot — run the app from a shell after creating a relay.json pointing at a local static server, or simpler: temporarily run `python3 -m http.server` is NOT enough (needs auth + JSON route). Quickest real check: `cd relay && npx wrangler dev` (local Worker at `http://localhost:8787`, secret via `.dev.vars` file containing `RELAY_TOKEN=test-token` — gitignored via `.wrangler`? add `.dev.vars` to `relay/.gitignore`), write `~/.claude/status-light/relay.json` pointing at it, POST a fake host snapshot with curl, then launch the app and confirm the remote row renders, is not clickable, and the light aggregates it:

```bash
echo 'RELAY_TOKEN=test-token' > relay/.dev.vars
printf '{"url":"http://localhost:8787","token":"test-token","host":"laptop"}' > ~/.claude/status-light/relay.json
curl -s -X POST http://localhost:8787/hosts/office-mini \
  -H 'Authorization: Bearer test-token' -H 'Content-Type: application/json' \
  --data '{"sessions":[{"session_id":"r1","state":"attention","cwd":"/w/mlb-props","term_program":"iTerm.app","tty":"/dev/ttys004","updated_at":'$(date +%s)',"agents":1,"title":"Improve win rate","shells":[],"background":false}]}'
swift run ClaudeStatusLight
```

Expected: menu shows `🔴 office-mini · mlb-props — Waiting for input · 1 agent` as a disabled row; aggregate light red; row disappears ~60 s after the last snapshot POST. Delete `~/.claude/status-light/relay.json` afterwards (until the real deploy in Task 10).

- [ ] **Step 4: Add `.dev.vars` to relay/.gitignore and commit**

```bash
printf '.dev.vars\n' >> relay/.gitignore
git add Sources/ClaudeStatusLight/AppDelegate.swift relay/.gitignore
git commit -m "Merge remote sessions into every surface with a relay-health footer"
```

---

### Task 10: Deploy + publisher install scripts, README, TODO

**Files:**
- Create: `scripts/deploy-relay.sh`
- Create: `scripts/install-publisher.sh`
- Modify: `README.md`, `TODO.md`

**Interfaces:**
- Consumes: everything above.
- Produces: one-command relay deploy (`relay.json` written locally), one-command publisher install for a remote Mac, user docs.

- [ ] **Step 1: Implement `scripts/deploy-relay.sh`**

```bash
#!/bin/bash
# Deploy the status relay Worker to the user's Cloudflare account and write
# ~/.claude/status-light/relay.json for the app / publisher / other scripts.
# Idempotent: re-deploys keep the existing token unless --rotate-token.
#
# Requires: npm, a Cloudflare account (wrangler will open a login browser
# window on first use).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$HOME/.claude/status-light/relay.json"

command -v npm >/dev/null || { echo "npm is required (install Node.js)" >&2; exit 1; }

cd "$HERE/relay"
npm install --no-fund --no-audit

# Keep an existing token across re-deploys so remote machines stay valid.
TOKEN=""
if [ -f "$CONFIG" ] && [ "${1:-}" != "--rotate-token" ]; then
    TOKEN="$(python3 -c "import json;print(json.load(open('$CONFIG')).get('token',''))" 2>/dev/null || true)"
fi
[ -n "$TOKEN" ] || TOKEN="$(openssl rand -hex 32)"

DEPLOY_OUT="$(npx wrangler deploy 2>&1 | tee /dev/stderr)"
URL="$(printf '%s' "$DEPLOY_OUT" | grep -Eo 'https://[A-Za-z0-9.-]+\.workers\.dev' | head -1)"
[ -n "$URL" ] || { echo "could not find the deployed URL in wrangler output" >&2; exit 1; }

printf '%s' "$TOKEN" | npx wrangler secret put RELAY_TOKEN

mkdir -p "$(dirname "$CONFIG")"
python3 - "$CONFIG" "$URL" "$TOKEN" <<'PY'
import json, socket, sys
path, url, token = sys.argv[1:4]
json.dump({"url": url, "token": token, "host": socket.gethostname().split(".")[0]},
          open(path, "w"), indent=2)
PY
chmod 600 "$CONFIG"

echo
echo "Relay deployed: $URL"
echo "Config written: $CONFIG (chmod 600)"
echo "Restart Claude Status Light to pick up remote sessions."
echo "For other Macs: copy $CONFIG over (edit \"host\"), then run scripts/install-publisher.sh there."
echo "For cloud sessions: scripts/enable-cloud-hooks.sh <repo>, then set STATUS_LIGHT_RELAY_URL/_TOKEN"
echo "  env vars and allowlist ${URL#https://} in your Claude Code cloud environment."
```

`chmod +x scripts/deploy-relay.sh`

- [ ] **Step 2: Implement `scripts/install-publisher.sh`**

```bash
#!/bin/bash
# Set up this Mac to publish its Claude Code sessions to the relay: builds
# the binary, installs it under ~/.claude/status-light/bin, and registers a
# launchd agent that keeps `--publish` running. Run on the REMOTE Mac (the
# office mini, etc.) — the Mac showing the light doesn't publish.
#
# Expects ~/.claude/status-light/relay.json to exist (copy it from the main
# Mac and change "host"), or pass:  --url <worker-url> --token <token> [--host <label>]
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$HOME/.claude/status-light/relay.json"
BIN_DIR="$HOME/.claude/status-light/bin"
LABEL="com.claude-status-light.publisher"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

URL="" TOKEN="" HOST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --url)   URL="$2"; shift 2 ;;
        --token) TOKEN="$2"; shift 2 ;;
        --host)  HOST="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [ -n "$URL" ] && [ -n "$TOKEN" ]; then
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
[ -f "$CONFIG" ] || { echo "no $CONFIG — copy it from your main Mac or pass --url/--token" >&2; exit 1; }

echo "Building…"
cd "$HERE"
swift build -c release
mkdir -p "$BIN_DIR"
cp "$(swift build -c release --show-bin-path)/ClaudeStatusLight" "$BIN_DIR/claude-status-light"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_DIR/claude-status-light</string>
        <string>--publish</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>StandardErrorPath</key><string>/tmp/claude-status-light-publisher.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Publisher installed and running (host: $(python3 -c "import json;print(json.load(open('$CONFIG'))['host'])"))."
echo "Logs: /tmp/claude-status-light-publisher.log"
```

`chmod +x scripts/install-publisher.sh`

- [ ] **Step 3: Smoke-test the scripts' inert paths**

Run: `bash -n scripts/deploy-relay.sh && bash -n scripts/install-publisher.sh && scripts/install-publisher.sh 2>&1 | head -2 || true`
Expected: both parse; install-publisher on a machine without relay.json (and no args) prints the "no …relay.json" error and exits 1 — do NOT run deploy-relay.sh for real in this task (that's the user's call; it opens a Cloudflare login).

- [ ] **Step 4: Document in README.md and TODO.md**

README: add a `## Remote sessions` section after "How it works", covering — in this order — what it does (sessions from other Macs and cloud sandboxes appear origin-labeled, not clickable, counted in the aggregate light), the architecture sketch below, setup for each leg (deploy-relay.sh on the main Mac; copy relay.json + install-publisher.sh per remote Mac; enable-cloud-hooks.sh + env vars + domain allowlist per repo/environment for cloud), liveness semantics (host rows drop ~60 s after its publisher goes quiet; cloud rows fade 30 min after their last event; `relay unreachable` footer when the app can't poll), and privacy (your own Cloudflare account; bearer token; states/titles only — no code or transcripts). Update the Layout tree with `relay/`, the three new scripts, `hooks/status-relay.sh`, and the new Swift files.

```
other Macs:  hooks → files → claude-status-light --publish ─┐
cloud repos: .claude/status-relay.sh ── raw hook events ────┼──▶ Worker + DO ──▶ app (GET /sessions, 4s)
this Mac:    hooks → files ─────────────────────────────────┘         (your Cloudflare account)
```

TODO.md: add the future-work list from the spec — Tailscale Funnel alternative relay, WebSocket push from the DO, "SSH to session" for remote host rows, Linux publisher, setting to exclude remote sessions from the aggregate light.

- [ ] **Step 5: Run everything, commit**

Run: `./scripts/test.sh && (cd relay && npx vitest run && npx tsc --noEmit) && bash Tests/relay_hook_test.sh && bash Tests/hook_test.sh`
Expected: all green.

```bash
git add scripts/deploy-relay.sh scripts/install-publisher.sh README.md TODO.md
git commit -m "Add relay deploy and publisher install scripts with docs"
```

---

## Verification (after all tasks)

1. `./scripts/test.sh` — Swift suite green.
2. `cd relay && npx vitest run && npx tsc --noEmit` — relay suite green, types clean.
3. `bash Tests/hook_test.sh && bash Tests/relay_hook_test.sh` — hook behavior green.
4. Manual (from Task 9 Step 3): `wrangler dev` + curl a fake host snapshot + launch app → remote row renders disabled, aggregate light reacts, row drops after 60 s of silence, footer appears when `wrangler dev` is killed.
5. Real deploy is a user step: `scripts/deploy-relay.sh`, then `scripts/install-publisher.sh` on the office mini over SSH, then `scripts/enable-cloud-hooks.sh` on a repo + environment config.
