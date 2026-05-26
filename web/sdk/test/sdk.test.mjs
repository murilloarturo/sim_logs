// SDK tests. Stub the browser globals before importing so the SDK loads
// in a "fake window" environment. Each test resets state via the SDK's
// `_resetForTesting` helper.

import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';

// ---- Browser-shape globals stub ----
const sentRequests = [];
const fetchStub = (input, init) => {
  const url = typeof input === 'string' ? input : (input && input.url) || '';
  sentRequests.push({ url, init });
  // Return a minimal Response-like object the SDK won't crash on.
  return Promise.resolve({
    status: 204,
    headers: new Headers(),
    clone() { return this; },
    async text() { return ''; },
  });
};

globalThis.window = globalThis;
globalThis.window.fetch = fetchStub;
globalThis.window.XMLHttpRequest = class { /* no-op stub */ };
globalThis.performance = globalThis.performance || { now: () => Date.now(), timeOrigin: Date.now() };
globalThis.Headers = globalThis.Headers || class FakeHeaders {
  constructor() { this._ = {}; }
  forEach(fn) { Object.entries(this._).forEach(([k, v]) => fn(v, k)); }
};

const { default: SimConsole } = await import('../src/index.js');

beforeEach(() => {
  sentRequests.length = 0;
  SimConsole._resetForTesting();
  // Re-install the fetch stub each test — the SDK replaces window.fetch on
  // bootstrap, so previous tests will have wrapped the stub.
  globalThis.window.fetch = fetchStub;
});

test('analytics() before bootstrap queues, flushes on bootstrap', async () => {
  SimConsole.analytics('queued_event');
  assert.equal(sentRequests.length, 0);

  SimConsole.bootstrap({ subsystem: 'test.app' });
  // Allow microtasks to drain so the queued POST goes out.
  await new Promise((r) => setImmediate(r));

  const events = sentRequests.map((r) => JSON.parse(r.init.body));
  // Bootstrap also emits a metric.launch.start, so 2 events expected.
  assert.equal(events.length, 2);
  const kinds = events.map((e) => e.kind).sort();
  assert.deepEqual(kinds, ['analytics.event', 'metric.launch.start']);
});

test('bootstrap installs fetch wrapper that captures user requests', async () => {
  SimConsole.bootstrap({ subsystem: 'test.app' });
  await new Promise((r) => setImmediate(r));
  sentRequests.length = 0; // clear bootstrap noise

  await globalThis.window.fetch('https://example.com/data');

  // The wrapper should have produced both a net.request (sent to bridge)
  // and called the original fetch with the user's URL.
  const userCall = sentRequests.find((r) => r.url === 'https://example.com/data');
  const eventCall = sentRequests.find((r) => /\/event$/.test(r.url));
  assert.ok(userCall, 'user request should still execute');
  assert.ok(eventCall, 'a net.request event should be POSTed to the bridge');

  const evt = JSON.parse(eventCall.init.body);
  assert.equal(evt.kind, 'net.request');
  assert.equal(evt.url, 'https://example.com/data');
  assert.equal(evt.method, 'GET');
});

test('fetch wrapper does NOT instrument its own bridge POSTs (no recursion)', async () => {
  SimConsole.bootstrap({ subsystem: 'test.app', bridge: 'http://127.0.0.1:9229' });
  await new Promise((r) => setImmediate(r));
  sentRequests.length = 0;

  // Manually POST to the bridge URL — this is what the SDK itself does
  // to send events. The wrapper must NOT emit a captured net.request
  // event for this call, otherwise an emit → captured → emit → ... loop
  // would form.
  await globalThis.window.fetch('http://127.0.0.1:9229/event', {
    method: 'POST',
    body: 'x',
  });

  // Exactly one outbound call (the bridge POST itself). Zero captured
  // net.request events emitted as a result.
  assert.equal(sentRequests.length, 1);
  assert.equal(sentRequests[0].url, 'http://127.0.0.1:9229/event');
});

test('metric.gauge emits a metric.gauge event with the supplied fields', async () => {
  SimConsole.bootstrap({ subsystem: 'test.app' });
  await new Promise((r) => setImmediate(r));
  sentRequests.length = 0;

  SimConsole.metric.gauge('cache.hit_rate', 0.87, { region: 'us-west-2' });
  await new Promise((r) => setImmediate(r));

  const evt = JSON.parse(sentRequests[0].init.body);
  assert.equal(evt.kind, 'metric.gauge');
  assert.equal(evt.name, 'cache.hit_rate');
  assert.equal(evt.value, 0.87);
  assert.deepEqual(evt.fields, { region: 'us-west-2' });
});

test('screen() updates context so the next analytics() carries screen name', async () => {
  SimConsole.bootstrap({ subsystem: 'test.app' });
  await new Promise((r) => setImmediate(r));
  sentRequests.length = 0;

  SimConsole.screen('Settings');
  SimConsole.analytics('button_tap', { id: 'save' });
  await new Promise((r) => setImmediate(r));

  const screenEvt = JSON.parse(sentRequests[0].init.body);
  const analyticsEvt = JSON.parse(sentRequests[1].init.body);
  assert.equal(screenEvt.kind, 'analytics.screen');
  assert.equal(screenEvt.name, 'Settings');
  assert.equal(analyticsEvt.kind, 'analytics.event');
  assert.equal(analyticsEvt.screen, 'Settings');
});

test('log() includes message + level + fields in the event payload', async () => {
  SimConsole.bootstrap({ subsystem: 'test.app' });
  await new Promise((r) => setImmediate(r));
  sentRequests.length = 0;

  SimConsole.log('something went wrong', 'error', { code: 'E_NET' });
  await new Promise((r) => setImmediate(r));

  const evt = JSON.parse(sentRequests[0].init.body);
  assert.equal(evt.kind, 'log.event');
  assert.equal(evt.message, 'something went wrong');
  assert.equal(evt.level, 'error');
  assert.deepEqual(evt.fields, { code: 'E_NET' });
});

test('bootstrap is a no-op when window is undefined (SSR safety)', async () => {
  // Save and remove the window to simulate SSR.
  const savedWindow = globalThis.window;
  delete globalThis.window;
  SimConsole._resetForTesting();

  // Should not throw.
  SimConsole.bootstrap({ subsystem: 'test.app' });

  // Restore for subsequent tests.
  globalThis.window = savedWindow;
  globalThis.window.fetch = fetchStub;
});
