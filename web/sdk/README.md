# @simconsole/web

Browser SDK that pipes analytics, logs, metrics, and network requests into
the [SimConsole](https://github.com/murilloarturo/sim_logs) macOS panel —
the same panel that surfaces iOS and Android dev events. Designed for
**dev-time observability**, not production.

## Install

```sh
npm install --save-dev @simconsole/web
```

You'll also want the bridge (`@simconsole/bridge`) running locally, and
the SimConsole macOS panel open. See the [project README](../README.md).

## Bootstrap

Call `bootstrap` once, as early as possible. The SDK is SSR-safe — it's a
no-op when there's no `window`.

```ts
import SimConsole from '@simconsole/web';

if (import.meta.env.DEV) {
  SimConsole.bootstrap({ subsystem: 'com.acme.web.checkout' });
}
```

Optional second argument: a non-default bridge URL.

```ts
SimConsole.bootstrap({
  subsystem: 'com.acme.web.checkout',
  bridge: 'http://127.0.0.1:9300',
});
```

## API

```ts
SimConsole.analytics(event: string, params?: object): void
SimConsole.screen(name: string, params?: object): void
SimConsole.log(message: string, level?: 'debug'|'info'|'warn'|'error', fields?: object): void

SimConsole.metric.gauge(name: string, value: number, fields?: object): void
SimConsole.metric.counter(name: string, increment?: number, fields?: object): void
SimConsole.metric.signpost(name: string, durationMs: number, fields?: object): void
SimConsole.metric.sample(name: string, value: number, fields?: object): void

SimConsole.appFinishLaunching(): void  // closes the launch-timing arc
```

API surface mirrors the iOS/Android SDKs so the same panel parsers handle
all three platforms with no per-platform code in the panel itself.

## Network auto-instrumentation

Bootstrap wraps `window.fetch` and `XMLHttpRequest` so every request your
app issues lands in the Network tab automatically — request/response
headers, body, status, timing — with no per-call wiring. The SDK
specifically excludes its own POSTs to the bridge URL to avoid an obvious
recursion bug.

```ts
SimConsole.bootstrap({ subsystem: 'com.acme.web' });
// Every fetch from now on is captured:
const data = await fetch('/api/users').then((r) => r.json());
```

## SSR / Next.js / Remix

Call `bootstrap` inside a client-only boundary:

```tsx
'use client';
import { useEffect } from 'react';
import SimConsole from '@simconsole/web';

export default function Root({ children }) {
  useEffect(() => {
    if (process.env.NODE_ENV === 'development') {
      SimConsole.bootstrap({ subsystem: 'com.acme.web' });
    }
  }, []);
  return children;
}
```

The SDK's top-level body is safe on a server (no `window` access until
`bootstrap` is called), but bundlers may still optimize the import away
if it's never referenced. Calling `bootstrap` inside `useEffect` is the
safest pattern.

## Production builds

Guard the import behind your dev flag — `import.meta.env.DEV` (Vite),
`process.env.NODE_ENV !== 'production'` (webpack/Next), etc. The SDK
ships as ESM and is tree-shakeable, but the bridge URL itself is `127.0.0.1`,
which won't reach a real backend even if it ships.

## Testing tips

The SDK exposes an `_resetForTesting()` helper that flushes internal
state. Useful for unit tests that bootstrap, exercise, and reset
between cases. Stub `globalThis.window`, `globalThis.fetch`, and
`globalThis.XMLHttpRequest` before importing the module.

## License

MIT
