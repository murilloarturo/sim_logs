// TypeScript declarations for @simconsole/web.
// Mirrors the iOS/Android SDK shapes so the events flowing into the
// SimConsole panel land in the same typed parsers.

export interface BootstrapOptions {
  /**
   * Unique identifier for the app/page emitting events. Surfaces in the
   * panel header and is used for per-session correlation. Convention:
   * reverse-DNS (`com.acme.web.checkout`) but any non-empty string works.
   */
  subsystem: string;
  /**
   * URL of the local bridge. Defaults to `http://127.0.0.1:9229`. Override
   * only if you've moved the bridge to a non-default port.
   */
  bridge?: string;
}

export type LogLevel = 'debug' | 'info' | 'warn' | 'error';

export interface Metric {
  gauge(name: string, value: number, fields?: Record<string, unknown>): void;
  counter(name: string, increment?: number, fields?: Record<string, unknown>): void;
  signpost(name: string, durationMs: number, fields?: Record<string, unknown>): void;
  sample(name: string, value: number, fields?: Record<string, unknown>): void;
}

export interface SimConsoleAPI {
  bootstrap(opts: BootstrapOptions): void;
  appFinishLaunching(): void;
  analytics(event: string, params?: Record<string, unknown>): void;
  screen(name: string, params?: Record<string, unknown>): void;
  log(message: string, level?: LogLevel, fields?: Record<string, unknown>): void;
  metric: Metric;
}

declare const SimConsole: SimConsoleAPI;
export default SimConsole;
export { SimConsole };

declare global {
  interface Window {
    SimConsole?: SimConsoleAPI;
  }
}
