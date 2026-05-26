// @simconsole/web — browser SDK for sim-console.
//
// Single-file JS. Works in three load shapes:
//   <script src="…/dist/simconsole.umd.js"></script>     ← exposes window.SimConsole
//   import SimConsole from '@simconsole/web';             ← ESM (this file)
//   const SimConsole = require('@simconsole/web');        ← (via build step)
//
// API parity with the iOS/Android SDKs:
//   SimConsole.bootstrap({ subsystem, bridge? })
//   SimConsole.appFinishLaunching()
//   SimConsole.analytics(event, params?)
//   SimConsole.screen(name, params?)
//   SimConsole.log(message, level?, fields?)
//   SimConsole.metric.gauge(name, value, fields?)
//   SimConsole.metric.counter(name, increment?, fields?)
//   SimConsole.metric.signpost(name, durationMs, fields?)
//   SimConsole.metric.sample(name, value, fields?)
//
// Auto-instruments `fetch` and `XMLHttpRequest` on bootstrap so network
// requests show up in the Network tab without any per-call wiring.

const DEFAULT_BRIDGE = 'http://127.0.0.1:9229';
const MAX_BODY_CHARS = 4000;

const state = {
  bridge: DEFAULT_BRIDGE,
  subsystem: 'web.app',
  bootstrapped: false,
  appStartTime: 0,
  queued: [],
  lastScreen: undefined,
  netIdCounter: 0,
  // Mocks fetched from the bridge. Stored as an array so we can preserve
  // the panel's intended order — first-match wins, same as the iOS
  // SimConsoleURLProtocol does for its own mocks. The SDK is told about
  // updates two ways: an initial GET /mocks at bootstrap, then live pushes
  // over Server-Sent Events at /mocks/stream.
  mocks: [],
  mocksEventSource: null,
  mocksPollTimer: null,
};

// ---------------------------------------------------------------------------
// Event transport

function send(evt) {
  evt.t = Date.now() / 1000;
  if (!state.bootstrapped) {
    state.queued.push(evt);
    return;
  }
  try {
    fetch(`${state.bridge}/event`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(evt),
      // keepalive lets events emitted during pagehide still flush.
      keepalive: true,
    }).catch(() => {});
  } catch (_) {
    // Bridge unreachable. Failing silently is intentional — we never want
    // SDK transport errors to surface in the host page.
  }
}

function flushQueue() {
  const q = state.queued.slice();
  state.queued.length = 0;
  q.forEach(send);
}

function isOwnBridgeUrl(url) {
  // The SDK's own POSTs to the bridge MUST NOT be instrumented. Without this
  // check, each emitted event causes a fetch -> a captured net.request event
  // -> another fetch -> ... unbounded recursion. Bridge URLs are uninteresting
  // anyway (they're dev-only).
  return !!url && state.bridge && url.indexOf(state.bridge) === 0;
}

function nextNetId() {
  return `web-${Date.now()}-${++state.netIdCounter}`;
}

// ---------------------------------------------------------------------------
// Mock cache + sync

function applyMockList(list) {
  state.mocks = Array.isArray(list) ? list.filter((m) => m && m.enabled !== false) : [];
}

async function loadMocksOnce() {
  try {
    const r = await fetch(`${state.bridge}/mocks`);
    if (!r.ok) return;
    applyMockList(await r.json());
  } catch (_) {
    // Bridge unreachable — leave mocks empty.
  }
}

function startMockStream() {
  // Prefer SSE (sub-second updates, no polling cost). If the browser
  // doesn't have EventSource (very old environments) or the bridge
  // declines the connection, fall back to a 3 s poll loop.
  if (typeof EventSource === 'undefined') {
    state.mocksPollTimer = setInterval(loadMocksOnce, 3000);
    return;
  }
  try {
    const es = new EventSource(`${state.bridge}/mocks/stream`);
    state.mocksEventSource = es;
    es.addEventListener('mocks', (ev) => {
      try { applyMockList(JSON.parse(ev.data)); } catch (_) {}
    });
    es.onerror = () => {
      // EventSource will keep reconnecting on its own with exponential
      // backoff. We don't need to do anything except keep the latest
      // snapshot until the next push arrives.
    };
  } catch (_) {
    state.mocksPollTimer = setInterval(loadMocksOnce, 3000);
  }
}

/**
 * Find the first enabled mock that matches `method` + `url`. Match rules
 * mirror the macOS panel's `MockStore.mock(matchingMethod:url:)`:
 *   - method comparison is case-insensitive
 *   - url comparison is *exact string equality*
 * The future bodyContains constraint isn't honored here yet; if the panel
 * sets it, the request just won't match and falls through to the network.
 */
function findMatchingMock(method, url) {
  const m = (method || 'GET').toUpperCase();
  for (const mock of state.mocks) {
    if (!mock || !mock.match) continue;
    if ((mock.match.method || '').toUpperCase() !== m) continue;
    if (mock.match.url !== url) continue;
    return mock;
  }
  return undefined;
}

/** Build a fetch-style Response from a Mock's response object. */
function synthesizeResponse(mock) {
  const headers = new Headers(mock.response?.headers || {});
  return new Response(mock.response?.body ?? '', {
    status: mock.response?.status ?? 200,
    headers,
  });
}

// ---------------------------------------------------------------------------
// Network instrumentation

function installFetchWrapper(root) {
  if (typeof root.fetch !== 'function') return;
  const orig = root.fetch.bind(root);
  root.fetch = async function patchedFetch(input, init) {
    init = init || {};
    const url = typeof input === 'string' ? input : input && input.url;
    if (isOwnBridgeUrl(url)) return orig(input, init);

    const method =
      (init && init.method) ||
      (typeof input !== 'string' && input && input.method) ||
      'GET';
    const id = nextNetId();
    const start = performance.now();
    const requestHeaders = headersToObject(
      init.headers || (typeof input !== 'string' && input && input.headers)
    );
    const requestBody = typeof init.body === 'string' ? init.body : undefined;

    // Mock check: if the panel's MockStore has an enabled entry for this
    // (method, url), short-circuit with the mocked Response instead of
    // hitting the network. Emit `net.request` + `net.response` with
    // `mocked: true` so the panel renders the "MOCKED" badge — exact
    // mirror of how iOS's SimConsoleURLProtocol behaves.
    const mock = findMatchingMock(method, url);
    if (mock) {
      send({
        kind: 'net.request', id, method, url,
        request_headers: requestHeaders, request_body: requestBody,
        mocked: true,
      });
      if (mock.delay_ms > 0) await new Promise((r) => setTimeout(r, mock.delay_ms));
      const resp = synthesizeResponse(mock);
      const clone = resp.clone();
      let body;
      try { body = await clone.text(); } catch (_) { body = undefined; }
      send({
        kind: 'net.response', id,
        status: resp.status,
        duration_ms: Math.round(performance.now() - start),
        response_headers: headersToObject(resp.headers),
        response_body: clipBody(body),
        mocked: true,
      });
      return resp;
    }

    send({
      kind: 'net.request', id, method, url,
      request_headers: requestHeaders, request_body: requestBody,
    });

    try {
      const resp = await orig(input, init);
      const clone = resp.clone();
      let body;
      try {
        body = await clone.text();
      } catch (_) {
        body = undefined;
      }
      send({
        kind: 'net.response',
        id,
        status: resp.status,
        duration_ms: Math.round(performance.now() - start),
        response_headers: headersToObject(resp.headers),
        response_body: clipBody(body),
      });
      return resp;
    } catch (err) {
      send({
        kind: 'net.error',
        id,
        duration_ms: Math.round(performance.now() - start),
        error: String(err),
      });
      throw err;
    }
  };
}

function installXhrWrapper(root) {
  if (typeof root.XMLHttpRequest === 'undefined') return;
  const X = root.XMLHttpRequest.prototype;
  const origOpen = X.open;
  const origSend = X.send;
  const origSetReqHeader = X.setRequestHeader;

  X.open = function patchedOpen(method, url, ...rest) {
    if (!isOwnBridgeUrl(url)) {
      this.__sc = { method, url, id: nextNetId(), headers: {}, start: 0 };
    }
    return origOpen.apply(this, [method, url, ...rest]);
  };

  X.setRequestHeader = function patchedSetHeader(k, v) {
    if (this.__sc) this.__sc.headers[k] = v;
    return origSetReqHeader.apply(this, [k, v]);
  };

  X.send = function patchedSend(body) {
    const sc = this.__sc;
    if (sc) {
      sc.start = performance.now();
      sc.body = typeof body === 'string' ? body : undefined;
      send({
        kind: 'net.request',
        id: sc.id,
        method: sc.method,
        url: sc.url,
        request_headers: sc.headers,
        request_body: sc.body,
      });
      this.addEventListener('loadend', () => {
        send({
          kind: 'net.response',
          id: sc.id,
          status: this.status,
          duration_ms: Math.round(performance.now() - sc.start),
          response_headers: parseRawXhrHeaders(this.getAllResponseHeaders()),
          response_body: typeof this.responseText === 'string'
            ? clipBody(this.responseText)
            : undefined,
        });
      });
    }
    return origSend.apply(this, [body]);
  };
}

function headersToObject(h) {
  if (!h) return {};
  if (typeof Headers !== 'undefined' && h instanceof Headers) {
    const o = {};
    h.forEach((v, k) => { o[k] = v; });
    return o;
  }
  if (Array.isArray(h)) {
    const o = {};
    h.forEach(([k, v]) => { o[k] = v; });
    return o;
  }
  return { ...h };
}

function parseRawXhrHeaders(raw) {
  const o = {};
  if (!raw) return o;
  raw.split(/\r?\n/).forEach((line) => {
    const i = line.indexOf(':');
    if (i > 0) o[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  });
  return o;
}

function clipBody(s) {
  if (typeof s !== 'string') return undefined;
  return s.length > MAX_BODY_CHARS ? s.slice(0, MAX_BODY_CHARS) + '…' : s;
}

// ---------------------------------------------------------------------------
// Public API

const SimConsole = {
  /**
   * Initialize the SDK. Must be called once, as early as possible — the
   * fetch/XHR wrappers only capture requests issued after bootstrap.
   * Safe to call from a server-side render context: it no-ops when there
   * is no `window`.
   */
  bootstrap(opts = {}) {
    if (typeof window === 'undefined') return; // SSR no-op

    if (opts.bridge) state.bridge = opts.bridge;
    if (opts.subsystem) state.subsystem = opts.subsystem;
    state.appStartTime = performance.now();
    state.bootstrapped = true;

    // Page discovery: identify which page is sending. Surfaces in the
    // panel's All tab today; future panel UI (W-D follow-up) will pin the
    // most recent session to the header so the user knows which tab/origin
    // is being watched when multiple browser tabs are connected.
    send({
      kind: 'session.register',
      subsystem: state.subsystem,
      origin: typeof location !== 'undefined' ? location.origin : '',
      pathname: typeof location !== 'undefined' ? location.pathname : '',
      title: typeof document !== 'undefined' ? document.title : '',
      user_agent: typeof navigator !== 'undefined' ? navigator.userAgent : '',
    });

    send({
      kind: 'metric.launch.start',
      ts: (typeof performance !== 'undefined' && performance.timeOrigin)
        ? performance.timeOrigin / 1000
        : Date.now() / 1000,
    });

    flushQueue();
    installFetchWrapper(window);
    installXhrWrapper(window);
    // Subscribe to the panel's MockStore via the bridge so fetch() can
    // short-circuit matching requests. Initial GET seeds the cache before
    // the SSE channel is established; the EventSource then keeps it live.
    loadMocksOnce().then(startMockStream);
  },

  /** Closes the launch-timing arc. Call once after first paint. */
  appFinishLaunching() {
    const ms = Math.round(performance.now() - state.appStartTime);
    send({ kind: 'metric.launch', ms, fields: {} });
  },

  analytics(event, params = {}) {
    // `kind` mirrors what the iOS/Android SDKs emit so the panel's
    // ingestAnalytics decoder parses these into typed AnalyticsEntry rows.
    send({
      kind: 'analytics',
      event,
      params,
      screen: state.lastScreen,
    });
  },

  screen(name, params = {}) {
    state.lastScreen = name;
    // Same convention as iOS/Android: kind=screen, screen field carries
    // the name. The panel's analytics decoder special-cases this.
    send({ kind: 'screen', screen: name, params });
  },

  log(message, level = 'info', fields = {}) {
    // `kind` matches the iOS/Android SDKs — the MCP server filters on this
    // string so cross-platform queries (`kind == "log"`) Just Work.
    send({ kind: 'log', message, level, fields });
  },

  metric: {
    gauge(name, value, fields = {}) {
      send({ kind: 'metric.gauge', name, value, fields });
    },
    counter(name, increment = 1, fields = {}) {
      send({
        kind: 'metric.counter',
        name,
        delta: increment,
        total: increment,
        fields,
      });
    },
    signpost(name, durationMs, fields = {}) {
      send({ kind: 'metric.signpost', name, duration_ms: durationMs, fields });
    },
    sample(name, value, fields = {}) {
      send({ kind: 'metric.sample', name, value, fields });
    },
  },

  /** @internal — exposed for tests so they can reset between cases. */
  _resetForTesting() {
    state.bridge = DEFAULT_BRIDGE;
    state.subsystem = 'web.app';
    state.bootstrapped = false;
    state.appStartTime = 0;
    state.queued.length = 0;
    state.lastScreen = undefined;
    state.netIdCounter = 0;
    state.mocks = [];
    if (state.mocksEventSource) {
      try { state.mocksEventSource.close(); } catch (_) {}
      state.mocksEventSource = null;
    }
    if (state.mocksPollTimer) {
      clearInterval(state.mocksPollTimer);
      state.mocksPollTimer = null;
    }
  },

  /** @internal — let tests inject a mock list without spinning up a bridge. */
  _setMocksForTesting(list) {
    applyMockList(list);
  },
};

// UMD-style global registration so `<script src=…>` users get window.SimConsole
// without an explicit import. ESM consumers get it via `import` below.
if (typeof window !== 'undefined') {
  window.SimConsole = SimConsole;
}

export default SimConsole;
export { SimConsole };
