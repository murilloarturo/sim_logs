// Tests for the bridge HTTP server. Uses Node's built-in test runner
// (`node --test`) and a per-test ephemeral port + temp output file so
// tests can run in parallel without colliding.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createBridge } from '../src/server.mjs';

function tmpOut(name) {
  return path.join(os.tmpdir(), `simconsole-bridge-test-${name}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.log`);
}

async function withBridge(opts, fn) {
  const port = 9229 + Math.floor(Math.random() * 5000);
  const b = createBridge({ ...opts, port, quiet: true });
  await b.start();
  try {
    return await fn(b, port);
  } finally {
    await b.close();
    try { fs.unlinkSync(b.eventsPath); } catch (_) {}
  }
}

test('POST /event appends one NDJSON line and increments count', async () => {
  await withBridge({ out: tmpOut('one') }, async (b, port) => {
    const r = await fetch(`http://127.0.0.1:${port}/event`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ kind: 'analytics.event', event: 'hello' }),
    });
    assert.equal(r.status, 204);
    const file = fs.readFileSync(b.eventsPath, 'utf8');
    assert.equal(file.trim().split('\n').length, 1);
    assert.match(file, /"kind":"analytics.event"/);
    assert.match(file, /"event":"hello"/);
    assert.equal(b.count, 1);
  });
});

test('POST /events appends every element of the array', async () => {
  await withBridge({ out: tmpOut('batch') }, async (b, port) => {
    const r = await fetch(`http://127.0.0.1:${port}/events`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify([
        { kind: 'log.event', message: 'a' },
        { kind: 'log.event', message: 'b' },
        { kind: 'log.event', message: 'c' },
      ]),
    });
    assert.equal(r.status, 204);
    const lines = fs.readFileSync(b.eventsPath, 'utf8').trim().split('\n');
    assert.equal(lines.length, 3);
    assert.equal(b.count, 3);
  });
});

test('POST /event with bad JSON returns 400 and does not increment count', async () => {
  await withBridge({ out: tmpOut('bad') }, async (b, port) => {
    const r = await fetch(`http://127.0.0.1:${port}/event`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{not json',
    });
    assert.equal(r.status, 400);
    assert.equal(b.count, 0);
  });
});

test('POST /events with non-array body returns 400', async () => {
  await withBridge({ out: tmpOut('badbatch') }, async (b, port) => {
    const r = await fetch(`http://127.0.0.1:${port}/events`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ not: 'an array' }),
    });
    assert.equal(r.status, 400);
  });
});

test('GET /health reports running state with count + path', async () => {
  await withBridge({ out: tmpOut('health') }, async (b, port) => {
    await fetch(`http://127.0.0.1:${port}/event`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ kind: 'log.event', message: 'x' }),
    });
    const r = await fetch(`http://127.0.0.1:${port}/health`);
    const j = await r.json();
    assert.equal(r.status, 200);
    assert.equal(j.ok, true);
    assert.equal(j.count, 1);
    assert.equal(j.out, b.eventsPath);
    assert.equal(typeof j.uptime_s, 'number');
  });
});

test('GET /mocks returns an empty array (Phase W-C placeholder)', async () => {
  await withBridge({ out: tmpOut('mocks') }, async (_b, port) => {
    const r = await fetch(`http://127.0.0.1:${port}/mocks`);
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), []);
  });
});

test('OPTIONS preflight returns 204 with permissive CORS headers', async () => {
  await withBridge({ out: tmpOut('cors') }, async (_b, port) => {
    const r = await fetch(`http://127.0.0.1:${port}/event`, {
      method: 'OPTIONS',
      headers: {
        Origin: 'http://example.com',
        'Access-Control-Request-Method': 'POST',
      },
    });
    assert.equal(r.status, 204);
    assert.equal(r.headers.get('access-control-allow-origin'), '*');
    assert.match(r.headers.get('access-control-allow-methods') || '', /POST/);
  });
});

test('default mode truncates the output file on startup', async () => {
  const out = tmpOut('truncate');
  fs.writeFileSync(out, 'stale\nstuff\n');
  await withBridge({ out }, async (b) => {
    // Existing content should be gone before any event is written.
    assert.equal(fs.readFileSync(b.eventsPath, 'utf8'), '');
  });
});

test('--append mode preserves existing content', async () => {
  const out = tmpOut('append');
  fs.writeFileSync(out, '{"kind":"text","line":"keep me"}\n');
  await withBridge({ out, append: true }, async (b, port) => {
    await fetch(`http://127.0.0.1:${port}/event`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ kind: 'log.event', message: 'new' }),
    });
    const lines = fs.readFileSync(b.eventsPath, 'utf8').trim().split('\n');
    assert.equal(lines.length, 2);
    assert.match(lines[0], /keep me/);
    assert.match(lines[1], /"new"/);
  });
});

test('unknown path returns 404', async () => {
  await withBridge({ out: tmpOut('404') }, async (_b, port) => {
    const r = await fetch(`http://127.0.0.1:${port}/nope`);
    assert.equal(r.status, 404);
  });
});
