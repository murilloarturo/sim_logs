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
| GET | `/mocks` | — | current mock rules (empty in 0.1.0; W-C will populate) |
| GET | `/health` | — | `{ ok, count, out, uptime_s }` |

All endpoints set `Access-Control-Allow-Origin: *` so a dev page on any
local port can POST without preflight friction.

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
