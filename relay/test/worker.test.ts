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
