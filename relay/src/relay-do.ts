import { DurableObject } from "cloudflare:workers";

export class RelayDO extends DurableObject<Env> {
  async fetch(_request: Request): Promise<Response> {
    return new Response("not found", { status: 404 });
  }
}
