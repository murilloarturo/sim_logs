#!/usr/bin/env node
// CLI entry — parses argv, runs the bridge, hooks up SIGINT for clean exit.

import { createBridge, DEFAULTS } from '../src/server.mjs';

async function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--port' || a === '-p') {
      opts.port = parseInt(argv[++i], 10);
    } else if (a === '--out' || a === '-o') {
      opts.out = argv[++i];
    } else if (a === '--host') {
      opts.host = argv[++i];
    } else if (a === '--append') {
      opts.append = true;
    } else if (a === '--quiet' || a === '-q') {
      opts.quiet = true;
    } else if (a === '--help' || a === '-h') {
      printHelp();
      process.exit(0);
    } else if (a === '--version' || a === '-v') {
      // Read version from package.json relative to this file.
      const url = new URL('../package.json', import.meta.url);
      const { readFile } = await import('node:fs/promises');
      const { version } = JSON.parse(await readFile(url, 'utf8'));
      console.log(version);
      process.exit(0);
    }
  }
  return opts;
}

function printHelp() {
  console.log(`Usage: simconsole-bridge [options]

Starts a local HTTP server that captures structured events from
@simconsole/web running in a browser page, and writes them to a file
the macOS SimConsole panel reads.

Options:
  -p, --port  <n>    Port to listen on (default ${DEFAULTS.port})
      --host  <ip>   Bind address (default ${DEFAULTS.host}; use 0.0.0.0 to
                     accept connections from other machines on the LAN)
  -o, --out   <path> NDJSON output file (default ~/.sim-console/web-bridge-events.log)
      --append       Don't truncate the output file on startup
  -q, --quiet        Suppress startup logs
  -v, --version      Print version and exit
  -h, --help         Show this help

Then launch the panel pointing at the same file:
  open -n -a SimConsole.app --args \\
    --platform web \\
    --tab "metric|Metrics|web" --tab "network|Network|web" \\
    --tab "analytics|Analytics|web" --tab "text|Logs|web" \\
    --tab "text|Errors|web" --tab "text|All|web"
`);
}

const bridge = createBridge(await parseArgs(process.argv.slice(2)));
await bridge.start();

process.on('SIGINT', async () => {
  console.log(`\nbridge shutting down (${bridge.count} events captured)`);
  await bridge.close();
  process.exit(0);
});
