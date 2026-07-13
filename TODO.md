# TODO

- **Subagent count badge is hard to see.** At menu bar size (18 px) the
  blue bottom-left badge (`IconRenderer.drawAgentBadge`) is tiny and the
  numeral is barely legible. Ideas when picking this up: enlarge the
  badge radius, bump contrast (darker ring / brighter fill), move it to
  a top corner clear of the dancing legs, or drop the numeral at small
  sizes and render just a solid dot — keeping the count only at dock
  size and in the menu/panel rows.

## Remote sessions — future work

- **API-token fallback for in-app deploy.** The Settings deploy rides
  wrangler's public OAuth client ID; if Cloudflare revokes it, add a flow
  that opens the dashboard's create-token page and accepts a pasted token.
- **Tailscale Funnel relay alternative.** For users who'd rather not use
  Cloudflare: serve the same API from a tiny local server exposed via
  Tailscale Funnel / plain tailnet.
- **WebSocket push from the DO.** Replace the app's 4 s polling with a
  Durable Object WebSocket so remote state changes land instantly.
- **"SSH to session" for remote host rows.** Clicking a remote Mac's row
  could open `ssh <host>` in a terminal instead of doing nothing.
- **Linux publisher.** The publisher loop is AppKit-free; port it so Linux
  boxes can report their sessions too.
- **Setting to exclude remote sessions from the aggregate light** — keep
  the rows but let the light reflect only this machine.
