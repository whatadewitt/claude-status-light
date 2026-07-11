export { RelayDO } from "./relay-do";

export default {
  async fetch(_request, _env, _ctx): Promise<Response> {
    return new Response("not found", { status: 404 });
  },
} satisfies ExportedHandler<Env>;
