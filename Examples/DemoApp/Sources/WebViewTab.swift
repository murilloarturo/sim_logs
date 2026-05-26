import SwiftUI
import WebKit
import SimConsole

/// PoC for WebView injection. Hosts a WKWebView whose JS environment is
/// pre-wired with a minimal `window.SimConsole` shim that forwards every
/// analytics/log/metric/network event back to native via a
/// WKScriptMessageHandler. The handler decodes the JSON and re-emits via
/// the *existing* `SimConsole` SPM APIs — the panel sees these events as
/// regular native emissions from this bundle id, no special handling
/// required.
///
/// This file lives in the DemoApp as a self-contained spike artifact.
/// If the architecture proves out, the next phase moves the bridge into
/// the SimConsole package as a public `attachToWebView(_:)` helper so
/// host apps don't have to copy the boilerplate.
struct WebViewTab: View {
    @State private var url: String = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Embedded WebView events flow through SimConsole's native SPM transport — same path as direct calls from Swift code.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    TextField("https://…  (try google.com or news.ycombinator.com)", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)
                    Button("Load") {
                        loadUrl()
                    }
                    .disabled(url.isEmpty)
                    Button("Demo") { url = "" }
                        .disabled(url.isEmpty)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                BridgedWebView(html: BridgedWebView.demoHTML, url: normalizedURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("WebView")
            .onAppear { SimConsole.screen("WebViewTab") }
        }
    }

    /// Empty string → use the bundled `demoHTML`. Non-empty → load that URL,
    /// adding a default scheme if the user didn't type one.
    private var normalizedURL: URL? {
        guard !url.isEmpty else { return nil }
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        return URL(string: s)
    }

    private func loadUrl() {
        // Bound to @State so BridgedWebView re-renders with the new URL.
        url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - WKWebView wrapper

/// Wraps a WKWebView in a SwiftUI representable. Loads `html` initially
/// then swaps to `url` (if non-nil) when the parent view re-renders.
/// The interesting work is in `makeUIView` — it builds the configuration
/// with the user-script injector + message handler.
private struct BridgedWebView: UIViewRepresentable {
    let html: String
    var url: URL? = nil

    func makeCoordinator() -> SimConsoleWebViewBridge {
        SimConsoleWebViewBridge()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()

        // 1) Register the JS-to-native message handler under "simconsole".
        //    The page's bridge stub calls
        //    `window.webkit.messageHandlers.simconsole.postMessage(jsonStr)`.
        ucc.add(context.coordinator, name: "simconsole")

        // 2) Inject the SimConsole bridge stub at document start so it's
        //    available before any page script runs and before any fetch()
        //    or XHR fires. WKUserScript is auto-re-injected on every new
        //    page load, so navigations (Load button → google.com → back
        //    to demo) keep the shim wired.
        let bridgeScript = WKUserScript(
            source: Self.bridgeJS,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        ucc.addUserScript(bridgeScript)

        config.userContentController = ucc

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.backgroundColor = .systemBackground
        webView.isOpaque = true
        // Initial paint: load the bundled demo HTML. updateUIView swaps
        // to a remote URL when the parent passes one.
        if let url = url {
            webView.load(URLRequest(url: url))
        } else {
            webView.loadHTMLString(html, baseURL: URL(string: "https://demo.local"))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Decide what should be on screen based on the bindings. We compare
        // against the current URL to avoid reloading on every state tick.
        if let url = url {
            if webView.url != url {
                webView.load(URLRequest(url: url))
            }
        } else if webView.url?.absoluteString != "https://demo.local/" {
            webView.loadHTMLString(html, baseURL: URL(string: "https://demo.local"))
        }
    }

    /// The JS source injected into every page loaded by this WebView.
    /// Three wrappers:
    ///   - `window.SimConsole.*` API (analytics / screen / log / metric.*)
    ///   - `window.fetch` capture
    ///   - `XMLHttpRequest` capture
    ///   - `console.log/warn/error/info/debug` pass-through to native
    ///     `SimConsole.log(..., level:)` so pages that don't know about
    ///     us still surface their console output in the Logs tab.
    static let bridgeJS = #"""
    (function () {
      const POST = (evt) => {
        try {
          evt.t = Date.now() / 1000;
          window.webkit.messageHandlers.simconsole.postMessage(JSON.stringify(evt));
        } catch (_) { /* handler not registered yet (shouldn't happen) */ }
      };

      let netIdCounter = 0;
      const nextId = () => `wkwv-${Date.now()}-${++netIdCounter}`;

      const SimConsole = {
        analytics(event, params = {}) {
          POST({ kind: 'analytics', event, params, screen: SimConsole._screen });
        },
        screen(name, params = {}) {
          SimConsole._screen = name;
          POST({ kind: 'screen', screen: name, params });
        },
        log(message, level = 'info', fields = {}) {
          POST({ kind: 'log', message, level, fields });
        },
        metric: {
          gauge(name, value, fields = {})           { POST({ kind: 'metric.gauge',    name, value, fields }); },
          counter(name, delta = 1, fields = {})     { POST({ kind: 'metric.counter',  name, delta, total: delta, fields }); },
          signpost(name, duration_ms, fields = {})  { POST({ kind: 'metric.signpost', name, duration_ms, fields }); },
        },
      };
      window.SimConsole = SimConsole;

      // ----- console.* mirror -----
      // Forward each console call to native as a log event AND pass through
      // to the original so DevTools / remote inspector still see it. We
      // intentionally don't recurse: native re-emit happens via the SPM
      // SimConsole.log call which writes via os.Logger, never back into JS.
      const LEVEL_MAP = { log: 'info', info: 'info', warn: 'warn', error: 'error', debug: 'debug' };
      Object.keys(LEVEL_MAP).forEach((name) => {
        const orig = console[name].bind(console);
        console[name] = function (...args) {
          try {
            // Stringify each arg the same way browsers do for the console:
            // strings as-is, objects via JSON.stringify with a guard for
            // circular refs (fall back to `String(...)`).
            const msg = args.map((a) => {
              if (typeof a === 'string') return a;
              try { return JSON.stringify(a); } catch (_) { return String(a); }
            }).join(' ');
            POST({ kind: 'log', message: msg, level: LEVEL_MAP[name], fields: { console: name } });
          } catch (_) { /* never let our wrap break the host page */ }
          return orig(...args);
        };
      });

      // ----- fetch wrapper -----
      const origFetch = window.fetch.bind(window);
      window.fetch = async function (input, init) {
        init = init || {};
        const url = typeof input === 'string' ? input : input && input.url;
        const method = (init && init.method) || (typeof input !== 'string' && input && input.method) || 'GET';
        const id = nextId();
        const start = performance.now();

        POST({ kind: 'net.request', id, method, url,
               request_headers: {}, request_body: typeof init.body === 'string' ? init.body : undefined });

        try {
          const resp = await origFetch(input, init);
          let body;
          // clone().text() throws on opaque cross-origin no-cors responses.
          // Swallow and keep the response/status/timing captured.
          try { body = await resp.clone().text(); } catch (_) {}
          POST({ kind: 'net.response', id,
                 status: resp.status,
                 duration_ms: Math.round(performance.now() - start),
                 response_headers: {},
                 response_body: body && body.length > 4000 ? body.slice(0, 4000) + '…' : body });
          return resp;
        } catch (err) {
          POST({ kind: 'net.error', id,
                 duration_ms: Math.round(performance.now() - start),
                 error: String(err) });
          throw err;
        }
      };

      // ----- XHR wrapper -----
      // Modern code uses fetch but legacy libs (jQuery $.ajax, axios's
      // XHR fallback, lots of older analytics SDKs) still use XHR. We
      // wrap open/send and listen for loadend so we capture both ends of
      // the request/response without polling readyState.
      if (typeof XMLHttpRequest !== 'undefined') {
        const X = XMLHttpRequest.prototype;
        const origOpen = X.open;
        const origSend = X.send;
        X.open = function (method, url, ...rest) {
          this.__sc = { method, url, id: nextId(), start: 0 };
          return origOpen.apply(this, [method, url, ...rest]);
        };
        X.send = function (body) {
          if (this.__sc) {
            const sc = this.__sc;
            sc.start = performance.now();
            POST({ kind: 'net.request', id: sc.id, method: sc.method, url: sc.url,
                   request_headers: {},
                   request_body: typeof body === 'string' ? body : undefined });
            this.addEventListener('loadend', () => {
              const text = typeof this.responseText === 'string' ? this.responseText : undefined;
              POST({ kind: 'net.response', id: sc.id,
                     status: this.status,
                     duration_ms: Math.round(performance.now() - sc.start),
                     response_headers: {},
                     response_body: text && text.length > 4000 ? text.slice(0, 4000) + '…' : text });
            });
          }
          return origSend.apply(this, [body]);
        };
      }
    })();
    """#

    /// The HTML page the WebView loads by default. Buttons exercise each
    /// instrumented path so the spike is self-validating without leaving
    /// the simulator.
    static let demoHTML = #"""
    <!DOCTYPE html>
    <html><head>
    <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Embedded WebView</title>
    <style>
      :root { color-scheme: light dark; }
      body { font: 14px/1.5 -apple-system, sans-serif; margin: 14px; }
      h2 { font-size: 11px; text-transform: uppercase; color: #888; margin: 14px 0 6px; }
      button {
        display: block; width: 100%; padding: 8px 10px; margin: 4px 0;
        background: color-mix(in srgb, currentColor 6%, transparent);
        border: 1px solid color-mix(in srgb, currentColor 15%, transparent);
        border-radius: 6px; font: inherit; text-align: left; color: inherit;
      }
      #log { margin-top: 12px; padding: 10px; background: #1c1c1e; color: #d4d4d4;
             font: 11px ui-monospace, Menlo, monospace; border-radius: 6px;
             max-height: 140px; overflow-y: auto; white-space: pre-wrap; }
    </style></head><body>
    <h2>Explicit SimConsole API</h2>
    <button type="button" id="b-analytics">SimConsole.analytics()</button>
    <button type="button" id="b-screen">SimConsole.screen('Settings')</button>
    <button type="button" id="b-gauge">SimConsole.metric.gauge()</button>
    <button type="button" id="b-signpost">SimConsole.metric.signpost()</button>

    <h2>Ambient console.* (no SDK call needed)</h2>
    <button type="button" id="b-clog">console.log({...})</button>
    <button type="button" id="b-cwarn">console.warn(...)</button>
    <button type="button" id="b-cerror">console.error(Error)</button>

    <h2>Network — fetch + XHR (auto-captured)</h2>
    <button type="button" id="b-fetch">fetch GET /posts/1</button>
    <button type="button" id="b-xhr">XHR GET /users/1</button>
    <button type="button" id="b-404">fetch /status/404</button>

    <div id="log">ready — WKUserScript injected at .atDocumentStart, console + fetch + XHR all wrapped</div>

    <script>
      const log = document.getElementById('log');
      function write(msg) {
        const ts = new Date().toISOString().slice(11, 19);
        log.textContent = `[${ts}] ${msg}\n` + log.textContent;
      }
      function on(id, fn) {
        document.getElementById(id).addEventListener('click', (ev) => {
          ev.preventDefault();
          try { fn(); } catch (e) { write('handler err: ' + e.message); }
        });
      }
      let n = 0;
      on('b-analytics',  () => { SimConsole.analytics('webview_button', { n: ++n }); write('analytics #' + n); });
      on('b-screen',     () => { SimConsole.screen('Settings', { source: 'webview' }); write('screen: Settings'); });
      on('b-gauge',      () => { SimConsole.metric.gauge('cache.hit_rate', Math.random()); write('gauge'); });
      on('b-signpost',   () => { SimConsole.metric.signpost('decode_feed', 80 + Math.floor(Math.random()*60)); write('signpost'); });

      on('b-clog',       () => { console.log('hello from console.log', { id: ++n, ts: Date.now() }); write('console.log fired'); });
      on('b-cwarn',      () => { console.warn('something looks fishy', { code: 'W001' }); write('console.warn fired'); });
      on('b-cerror',     () => { console.error(new Error('demo error: kaboom')); write('console.error fired'); });

      on('b-fetch', async () => {
        try {
          const r = await fetch('https://jsonplaceholder.typicode.com/posts/1');
          const j = await r.json();
          write('fetch /posts/1 → ' + JSON.stringify(j).slice(0, 70));
        } catch (e) { write('fetch err: ' + e.message); }
      });
      on('b-xhr', () => {
        const xhr = new XMLHttpRequest();
        xhr.open('GET', 'https://jsonplaceholder.typicode.com/users/1');
        xhr.onload = () => write('XHR /users/1 → status ' + xhr.status);
        xhr.send();
      });
      on('b-404', async () => {
        try {
          const r = await fetch('https://httpbin.org/status/404');
          write('fetch /status/404 → ' + r.status);
        } catch (e) { write('fetch err: ' + e.message); }
      });
    </script>
    </body></html>
    """#
}

// MARK: - JS → native bridge handler

/// Decodes JSON events posted by the injected JS SDK and re-emits them
/// via the existing iOS `SimConsole` SPM APIs. From the panel's POV, the
/// events look identical to any other native call — same `subsystem`,
/// same `os.Logger` path.
final class SimConsoleWebViewBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ uc: WKUserContentController, didReceive msg: WKScriptMessage) {
        guard msg.name == "simconsole" else { return }

        // Each postMessage payload is a JSON string. Parse it and route by
        // `kind`. Anything we don't recognize is dropped on the floor —
        // we don't want a malformed event to take down the bridge.
        guard let body = msg.body as? String,
              let data = body.data(using: .utf8),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = dict["kind"] as? String
        else { return }

        switch kind {
        case "analytics":
            let event = dict["event"] as? String ?? "(unnamed)"
            let params = (dict["params"] as? [String: Any]) ?? [:]
            let screen = dict["screen"] as? String
            SimConsole.analytics(event: event, params: params, screen: screen)

        case "screen":
            let name = dict["screen"] as? String ?? "(unnamed)"
            let params = (dict["params"] as? [String: Any]) ?? [:]
            SimConsole.screen(name, params: params)

        case "log":
            let message = dict["message"] as? String ?? ""
            let levelStr = dict["level"] as? String ?? "info"
            let fields = (dict["fields"] as? [String: Any]) ?? [:]
            SimConsole.log(message, level: parseLevel(levelStr), fields: fields)

        case "metric.gauge":
            if let name = dict["name"] as? String, let value = dict["value"] as? Double {
                SimConsole.metric.gauge(name, value: value, fields: (dict["fields"] as? [String: Any]) ?? [:])
            }
        case "metric.counter":
            if let name = dict["name"] as? String, let delta = dict["delta"] as? Double {
                SimConsole.metric.counter(name, increment: delta, fields: (dict["fields"] as? [String: Any]) ?? [:])
            }
        case "metric.signpost":
            if let name = dict["name"] as? String, let durationMs = dict["duration_ms"] as? Int {
                SimConsole.metric.signpost(name, durationMs: durationMs, fields: (dict["fields"] as? [String: Any]) ?? [:])
            }

        case "net.request":
            if let id = dict["id"] as? String,
               let method = dict["method"] as? String,
               let url = dict["url"] as? String {
                SimConsole.network(
                    request: id,
                    method: method,
                    url: url,
                    headers: (dict["request_headers"] as? [String: String]) ?? [:],
                    body: dict["request_body"] as? String
                )
            }
        case "net.response":
            if let id = dict["id"] as? String,
               let status = dict["status"] as? Int,
               let durationMs = dict["duration_ms"] as? Int {
                SimConsole.network(
                    response: id,
                    status: status,
                    durationMs: durationMs,
                    headers: (dict["response_headers"] as? [String: String]) ?? [:],
                    body: dict["response_body"] as? String
                )
            }
        case "net.error":
            if let id = dict["id"] as? String, let durationMs = dict["duration_ms"] as? Int {
                let err = dict["error"] as? String ?? "(unknown)"
                SimConsole.network(error: id, durationMs: durationMs, error: err)
            }

        default:
            // Unknown kind — silently ignore. Could log a diag in a future
            // iteration if it becomes useful for debugging.
            break
        }
    }

    private func parseLevel(_ s: String) -> SimConsole.Level {
        switch s.lowercased() {
        case "debug": return .debug
        case "warn", "warning": return .warn
        case "error", "fault": return .error
        default: return .info
        }
    }
}
