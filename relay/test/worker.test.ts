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

  it("rejects the correct token without the Bearer scheme", async () => {
    const res = await exports.default.fetch(
      new Request("https://relay.example/sessions", {
        headers: { Authorization: "test-token" },
      }),
    );
    expect(res.status).toBe(401);
  });

  it("rejects Bearer followed by only whitespace", async () => {
    const res = await exports.default.fetch(
      new Request("https://relay.example/sessions", {
        headers: { Authorization: "Bearer   " },
      }),
    );
    expect(res.status).toBe(401);
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
