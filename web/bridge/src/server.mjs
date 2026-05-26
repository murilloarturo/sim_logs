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
      // Phase W-C: this will return the panel's MockStore contents.
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end('[]');
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
        resolve();
      });
    });
  }

  function close() {
    return new Promise((resolve) => server.close(() => resolve()));
  }

  return {
    server,
    start,
    close,
    get eventsPath() {
      return cfg.out;
    },
    get count() {
      return count;
    },
  };
}
