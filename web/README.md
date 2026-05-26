# sim-console — web platform

Brings the SimConsole macOS panel to **browser apps**, alongside the existing
iOS and Android targets. Same six tabs (Metrics / Network / Analytics / Logs
/ Errors / All), same MCP server for agentic queries, same NDJSON event
schema. Just a tiny browser SDK + a local HTTP bridge in between.

```
┌──────────────────┐  POST 127.0.0.1:9229/event   ┌──────────────────┐
│ Browser tab      │ ───────────────────────────► │ @simconsole/     │
│ (dev build)      │                              │   bridge (Node)  │
│ ┌──────────────┐ │ ─── WS /mocks ──────────────►│                  │
│ │@simconsole/  │ │                              │                  │
│ │   web SDK    │ │                              │                  │
│ └──────────────┘ │                              └────────┬─────────┘
└──────────────────┘                                       │ append
                                                           ▼
                                        ~/.sim-console/web-bridge-events.log
                                                           │ tail -n 0 -F
                                                           ▼
                                              ┌────────────────────┐
                                              │  SimConsole.app    │
                                              │  --platform web    │
                                              └────────────────────┘
```

## Packages

| Package | Purpose | Distributable |
|---|---|---|
| [`@simconsole/web`](./sdk/) | Browser SDK — `bootstrap`, `analytics`, `log`, `metric`, auto-instruments fetch + XHR | npm |
| [`@simconsole/bridge`](./bridge/) | Local HTTP server that receives events and writes NDJSON for the panel | npm (CLI: `simconsole-bridge`) |

The macOS panel needs no separate web install — `--platform web` mode is
built into the same `SimConsole.app` binary that supports iOS and Android.

## Quick start

```sh
# 1. Install the SDK in your web app (dev-only dep)
npm install --save-dev @simconsole/web

# 2. Bootstrap it as early as possible in your entry file
import SimConsole from '@simconsole/web';
if (import.meta.env.DEV) {
  SimConsole.bootstrap({ subsystem: 'com.acme.web.checkout' });
}

# 3. Run the bridge alongside your dev server
npx @simconsole/bridge

# 4. Launch the panel (in a separate terminal)
open -n -a SimConsole.app --args \
  --platform web \
  --tab "metric|Metrics|web" --tab "network|Network|web" \
  --tab "analytics|Analytics|web" --tab "text|Logs|web" \
  --tab "text|Errors|web" --tab "text|All|web"
```

The `/sim-console` skill automates steps 1, 3, and 4 in projects with a
`package.json` and a recognized bundler config — see the skill docs.

## What you get

- **Network tab** — every `fetch` and `XMLHttpRequest` your page issues,
  with full request/response headers, bodies, status, and timing. Much
  easier to scan than the browser's built-in DevTools, especially across
  page reloads.
- **Analytics tab** — every `SimConsole.analytics(event, params)` call,
  searchable by event name or parameter value. Each row expands to show
  the full param payload.
- **Logs tab** — every `SimConsole.log(message, level, fields)` call,
  with level-colored rows and free-text filter.
- **Metrics tab** — gauges, counters, signposts. Live sparklines for
  recurring samples.
- **Errors tab** — log entries at `error` / `fault` level, broken out.
- **All tab** — the firehose.

## Why not just use DevTools?

DevTools' Network panel is built for inspecting individual requests in
detail, not for **scanning many sessions** to spot regressions. It also
can't show analytics events or custom logs without you hand-correlating
with the Console panel. SimConsole reuses the same UI as our iOS/Android
panels so you can compare cross-platform behavior side by side.

## Status

Phase W-A (shipping now): bridge + SDK + `--platform web` panel support.

Roadmap: mock injection (W-C), page-discovery for multi-tab pages (W-D),
auto-integration via the `/sim-console` skill (W-E), npm publish + demo
app (W-F).
