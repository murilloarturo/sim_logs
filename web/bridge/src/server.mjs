// sim-console-bridge — local HTTP server that bridges a browser SDK to the
// macOS SimConsole panel. Accepts NDJSON event POSTs from a web page and
// appends them to a file the panel reads via `tail -n 0 -F`.
//
// Distribution: published to npm as `@simconsole/bridge` with a `bin` entry
// at `simconsole-bridge` so users can run it with `npx`. No runtime deps.
//
// Endpoints (all CORS-permissive for dev use):
//   POST /event          single NDJSON event (raw JSON body)
//   POST /events         JSON array of NDJSON events (batch)
//   GET  /mocks          current mock rules (empty array for now;
//                        Phase W-C will sync with the panel's MockStore)
//   GET  /health         { ok, count, out, uptime_s }
//
// Event format: whatever shape the panel expects per `kind`. The web SDK
// produces shapes identical to the iOS/Android SDKs so the panel's
// ingestMetric/Analytics/Network/Text decoders parse them unchanged.

import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export const DEFAULTS = Object.freeze({
  port: 9229,
  host: '127.0.0.1',
  out: path.join(os.homedir(), '.sim-console', 'web-bridge-events.log'),
  quiet: false,
  // When set, the bridge serves mocks from
  //   ~/.sim-console/mocks-<bundleId>.json
  // — the same file the macOS panel's MockStore writes. Empty means
  // "no mock support" and /mocks returns [].
  bundleId: '',
});

/**
 * Start the bridge. Returns `{ server, close, eventsPath, getCount }`.
 * Exported so tests can drive it without going through the CLI.
 *
 * @param {object} [opts]
 * @param {number} [opts.port]
 * @param {string} [opts.host]
 * @param {string} [opts.out]   absolute path where events are appended
 * @param {boolean} [opts.quiet]
 * @param {boolean} [opts.append] if true, don't truncate the events file
 *   on startup. Default false (truncate), so each run starts clean.
 */
export function createBridge(opts = {}) {
  const cfg = { ...DEFAULTS, ...opts };
  const startedAt = Date.now();
  let count = 0;

  fs.mkdirSync(path.dirname(cfg.out), { recursive: true });
  if (!opts.append) fs.writeFileSync(cfg.out, '');

  // ---- Mock bridge state ----
  // Path the macOS panel's MockStore writes when given the same bundleId.
  // We re-read it whenever fs.watch fires and broadcast the new list to
  // any connected SSE clients.
  const mocksPath = cfg.bundleId
    ? path.join(os.homedir(), '.sim-console', `mocks-${cfg.bundleId}.json`)
    : '';
  const sseClients = new Set();

  function readMocks() {
    if (!mocksPath) return [];
    try {
      const raw = fs.readFileSync(mocksPath, 'utf8');
      const file = JSON.parse(raw);
      return Array.isArray(file?.mocks) ? file.mocks : [];
    } catch (_) {
      return [];
    }
  }

  function broadcastMocks() {
    const payload = JSON.stringify(readMocks());
    for (const res of sseClients) {
      try {
        res.write(`event: mocks\ndata: ${payload}\n\n`);
      } catch (_) {
        sseClients.delete(res);
      }
    }
  }

  let mocksWatcher = null;
  if (mocksPath) {
    // Ensure the directory exists so fs.watch doesn't throw if the panel
    // hasn't created any mocks yet.
    fs.mkdirSync(path.dirname(mocksPath), { recursive: true });
    // Watch the directory (not the file) because the panel writes
    // mocks atomically — write to a temp + rename, which file-mode watch
    // would miss after the first rename.
    try {
      mocksWatcher = fs.watch(path.dirname(mocksPath), (_evt, fname) => {
        if (fname === path.basename(mocksPath)) broadcastMocks();
      });
    } catch (_) {
      // If watch fails (rare — e.g. on macOS over an NFS mount), SDK
      // polling on /mocks every 3 s is the fallback.
    }
  }

  function log(...args) {
    if (!cfg.quiet) console.log(...args);
  }

  function writeEvent(evt) {
    fs.appendFileSync(cfg.out, JSON.stringify(evt) + '\n');
    count++;
  }

  function setCors(res) {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type');
  }

  function readBody(req) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      req.on('error', reject);
    });
  }

  const server = http.createServer(async (req, res) => {
    setCors(res);
    if (req.method === 'OPTIONS') {
      res.writeHead(204).end();
      return;
    }
    const url = new URL(req.url, `http://${cfg.host}:${cfg.port}`);

    if (req.method === 'GET' && url.pathname === '/health') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(
        JSON.stringify({
          ok: true,
          count,
          out: cfg.out,
          uptime_s: Math.round((Date.now() - startedAt) / 1000),
        })
      );
      return;
    }

    if (req.method === 'GET' && url.pathname === '/mocks') {
      // Reads the panel's MockStore file directly (it owns the data —
      // we just serve a snapshot). Returns [] when no bundleId was given
      // or when the panel hasn't written any mocks yet.
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(readMocks()));
      return;
    }

    if (req.method === 'GET' && url.pathname === '/mocks/stream') {
      // Server-Sent Events stream — every time the panel's mock file
      // changes, all connected clients receive an `event: mocks` push
      // with the new list. SDK uses this for sub-second mock updates;
      // pollers can fall back to /mocks every few seconds.
      res.writeHead(200, {
        'Content-Type': 'text/event-stream',
        'Cache-Control': 'no-store',
        Connection: 'keep-alive',
      });
      // Send the current snapshot immediately so a freshly-connected
      // SDK doesn't have to wait for the next file change.
      res.write(`event: mocks\ndata: ${JSON.stringify(readMocks())}\n\n`);
      sseClients.add(res);
      req.on('close', () => sseClients.delete(res));
      return;
    }

    if (req.method === 'POST' && url.pathname === '/event') {
      try {
        const evt = JSON.parse(await readBody(req));
        writeEvent(evt);
        res.writeHead(204).end();
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'text/plain' });
        res.end('bad event: ' + e.message);
      }
      return;
    }

    if (req.method === 'POST' && url.pathname === '/events') {
      try {
        const arr = JSON.parse(await readBody(req));
        if (!Array.isArray(arr)) throw new Error('expected array');
        for (const evt of arr) writeEvent(evt);
        res.writeHead(204).end();
      } catch (e) {
        res.writeHead(400, { 'Content-Type': 'text/plain' });
        res.end('bad batch: ' + e.message);
      }
      return;
    }

    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found');
  });

  function start() {
    return new Promise((resolve) => {
      server.listen(cfg.port, cfg.host, () => {
        log(`sim-console-bridge listening on http://${cfg.host}:${cfg.port}`);
        log(`writing events to ${cfg.out}`);
        if (cfg.bundleId) log(`watching mocks at ${mocksPath}`);
        resolve();
      });
    });
  }

  function close() {
    if (mocksWatcher) {
      try { mocksWatcher.close(); } catch (_) {}
    }
    for (const res of sseClients) {
      try { res.end(); } catch (_) {}
    }
    sseClients.clear();
    return new Promise((resolve) => server.close(() => resolve()));
  }

  return {
    server,
    start,
    close,
    broadcastMocks,
    get eventsPath() {
      return cfg.out;
    },
    get mocksPath() {
      return mocksPath;
    },
    get count() {
      return count;
    },
  };
}
