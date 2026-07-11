export { RelayDO } from "./relay-do";

/// Timing-safe bearer check: hash both sides so lengths always match, then
/// constant-time compare. Direct string comparison leaks via timing.
async function authorized(request: Request, env: Env): Promise<boolean> {
  const header = request.headers.get("Authorization") ?? "";
  const match = header.match(/^Bearer\s+(.+)$/i);
  const provided = match?.[1] ?? "";
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
