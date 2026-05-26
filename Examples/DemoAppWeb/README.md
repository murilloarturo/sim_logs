# DemoAppWeb

A zero-build, vanilla-HTML demo page for the `@simconsole/web` SDK. Mirrors
the iOS / Android demo apps in spirit — buttons for analytics, network,
metrics, and logs — but everything fits in a single `index.html`.

## Run it

```sh
# From the repo root:
# 1. Start the bridge (in one terminal)
node web/bridge/bin/simconsole-bridge.mjs

# 2. Start a static file server (in another terminal)
python3 -m http.server 8765

# 3. Launch the panel
open -n -a Tools/SimConsole.app --args \
  --platform web \
  --tab "metric|Metrics|web" --tab "network|Network|web" \
  --tab "analytics|Analytics|web" --tab "text|Logs|web" \
  --tab "text|Errors|web" --tab "text|All|web"

# 4. Open the demo page
open "http://localhost:8765/Examples/DemoAppWeb/"
```

Or just run `/sim-console launch` and the skill wires all four steps up
for you. See `.claude/skill/SKILL.md` for the auto-integration flow.

## What's instrumented

| Section | Behavior |
|---|---|
| Metrics | gauges, counters, signposts, a deliberate 600 ms main-thread hang |
| Network | GET/POST/4xx/slow, all auto-captured via the SDK's `fetch` wrapper |
| Analytics | `analytics()` + `screen()` calls with mixed parameter shapes |
| Logs | `log()` at .info/.warn/.error with rich field payloads |
| Auto-fire | Periodic mixed-stream activity, useful for stress-testing the panel |

The page imports the SDK source directly via ESM (`../../web/sdk/src/index.js`)
so you can hack on the SDK and refresh the browser without rebuilding —
no bundler involved.
