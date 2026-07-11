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
