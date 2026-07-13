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

interface PairRecord {
  url: string;
  token: string;
  expires_at: number;
}

/// Pairing codes hand the relay config to a new machine. Single-use,
/// short-lived, 128-bit — the code itself is the credential, so entropy
/// (not rate limiting) is the defense.
export const PAIR_TTL_S = 10 * 60;

/// Single-instance store for everything remote. Hosts push whole snapshots
/// (the snapshot doubles as the host's heartbeat); cloud sandboxes push raw
/// hook payloads that get classified here. All staleness math everywhere
/// uses this object's clock — client clocks are never trusted.
export class RelayDO extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const now = Math.floor(Date.now() / 1000);

    if (request.method === "POST" && url.pathname.startsWith("/hosts/")) {
      let name: string;
      try {
        name = decodeURIComponent(url.pathname.slice("/hosts/".length));
      } catch {
        return new Response("invalid host name", { status: 400 });
      }
      if (!name) return new Response("missing host name", { status: 400 });
      // A malformed or shapeless body must never replace a good snapshot,
      // so reject anything whose sessions isn't an array (clear-all is an
      // explicit empty array, never a parse failure).
      const body = (await request.json().catch(() => null)) as { sessions?: unknown } | null;
      if (body === null || !Array.isArray(body.sessions)) {
        return new Response("invalid body", { status: 400 });
      }
      const record: HostRecord = { name, received_at: now, sessions: body.sessions };
      await this.ctx.storage.put(`host:${name}`, record);
      return Response.json({ ok: true });
    }

    if (request.method === "POST" && url.pathname === "/hook") {
      const payload = (await request.json().catch(() => ({}))) as Record<string, unknown>;
      await this.ingestHook(payload, now);
      return Response.json({ ok: true });
    }

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
      } else if (key.startsWith("pair:")) {
        // Never included in the response; lazy pruning only, so codes
        // don't outlive their TTL in storage.
        if ((value as PairRecord).expires_at <= now) {
          await this.ctx.storage.delete(key);
        }
      }
    }
    return { now, hosts, cloud };
  }
}
