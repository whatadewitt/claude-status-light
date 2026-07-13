import { describe, it, expect } from "vitest";
import { env } from "cloudflare:workers";
import { runInDurableObject } from "cloudflare:test";
import { CLOUD_TTL_S } from "../src/classify";
import { PAIR_TTL_S } from "../src/relay-do";
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

  it("rejects malformed JSON and leaves the prior snapshot untouched", async () => {
    const stub = relay();
    await post(stub, "/hosts/office-mini", { sessions: [wireSession] });
    const res = await stub.fetch("https://relay/hosts/office-mini", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "{not json",
    });
    expect(res.status).toBe(400);
    const body = await sessions(stub);
    expect(body.hosts[0].sessions).toEqual([wireSession]);
  });

  it("rejects a body whose sessions is not an array", async () => {
    const res = await post(relay(), "/hosts/office-mini", { sessions: "nope" });
    expect(res.status).toBe(400);
  });

  it("rejects a host name with malformed percent-escapes", async () => {
    const res = await post(relay(), "/hosts/bad%zz", { sessions: [] });
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
      const ctx = (instance as unknown as { ctx: DurableObjectState }).ctx;
      const record = await ctx.storage.get<{ received_at: number }>("cloud:old");
      await ctx.storage.put("cloud:old", {
        ...record!,
        received_at: record!.received_at - CLOUD_TTL_S - 10,
      });
    });
    const body = await sessions(stub);
    expect(body.cloud).toEqual([]);
    await runInDurableObject(stub, async (instance: RelayDO) => {
      const ctx = (instance as unknown as { ctx: DurableObjectState }).ctx;
      expect(await ctx.storage.get("cloud:old")).toBeUndefined();
    });
  });
});

describe("routing", () => {
  it("404s unknown paths", async () => {
    const res = await relay().fetch("https://relay/nope");
    expect(res.status).toBe(404);
  });
});

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
