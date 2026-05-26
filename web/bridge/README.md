# @simconsole/bridge

Local HTTP server that captures structured events from
[`@simconsole/web`](https://www.npmjs.com/package/@simconsole/web) running in
a browser page and writes them to a file the SimConsole macOS panel reads
via `tail -n 0 -F`.

Lives at `127.0.0.1:9229` by default. No runtime dependencies. No network
egress — everything stays on your machine.

## Install

```sh
npm install --save-dev @simconsole/bridge
```

Or run once without installing:

```sh
npx @simconsole/bridge
```

## CLI

```
Usage: simconsole-bridge [options]

Options:
  -p, --port  <n>    Port to listen on (default 9229)
      --host  <ip>   Bind address (default 127.0.0.1; use 0.0.0.0 to accept
                     LAN connections from other devices on the network)
  -o, --out   <path> NDJSON output file
                     (default ~/.sim-console/web-bridge-events.log)
      --append       Don't truncate the output file on startup
  -q, --quiet        Suppress startup logs
  -v, --version      Print version and exit
  -h, --help         Show this help
```

## Endpoints

| Method | Path | Body | Purpose |
|---|---|---|---|
| POST | `/event` | single NDJSON event | append one event |
| POST | `/events` | JSON array of events | batch append |
| GET | `/mocks` | — | snapshot of the panel's MockStore for this `--bundle-id` |
| GET | `/mocks/stream` | — | Server-Sent Events; pushes mock updates as they happen |
| GET | `/health` | — | `{ ok, count, out, uptime_s }` |

All endpoints set `Access-Control-Allow-Origin: *` so a dev page on any
local port can POST without preflight friction.

### Mock sync

When the bridge is started with `--bundle-id <id>`, it watches
`~/.sim-console/mocks-<id>.json` — the file the macOS panel's `MockStore`
writes — and serves a snapshot at `GET /mocks` plus live updates over
`GET /mocks/stream` (Server-Sent Events).

The `@simconsole/web` SDK uses both: a one-shot GET on bootstrap to seed
its in-memory cache, then an `EventSource` connection to `/mocks/stream`
so panel edits (Add Mock, Edit, Remove) take effect on the next request
without a page reload.

## Programmatic use

```js
import { createBridge } from '@simconsole/bridge';

const b = createBridge({ port: 9229, out: '/tmp/my-events.log' });
await b.start();
// ... do stuff ...
await b.close();
```

## Pair with SimConsole.app

```sh
open -n -a SimConsole.app --args \
  --platform web \
  --tab "metric|Metrics|web" --tab "network|Network|web" \
  --tab "analytics|Analytics|web" --tab "text|Logs|web" \
  --tab "text|Errors|web" --tab "text|All|web"
```

The panel's tail subprocess attaches to `~/.sim-console/web-bridge-events.log`
(or whatever path you pass via `--web-source`).
