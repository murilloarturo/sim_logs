---
name: sim-console
description: Install, integrate, and launch sim_logs — a live structured-log overlay that sits beside the iOS Simulator and renders structured analytics + network rows from an in-app SDK (SimConsole). Use when the user wants to view live analytics events, network requests, or structured logs from an iOS app running on a simulator, when they say things like "open sim-console", "show me the network logs", "integrate sim_logs into this project", or "install sim-console". Three sub-commands: `install` (clone repo + build binary), `integrate` (add the SwiftPM dependency + bootstrap call + URLProtocol to the current iOS project), `launch` (run the macOS panel beside the booted simulator). The skill is the single entry point — never have the user run shell commands by hand.
---

This skill manages **sim_logs** — a developer tool that streams structured analytics, network, and log events from an iOS app onto a SwiftUI panel beside the Simulator window. The companion in-app SDK (`SimConsole`) emits JSON via `os.Logger` and the macOS app (`sim-console`) renders typed rows.

Project URL: `https://github.com/murilloarturo/sim_logs`

The skill takes one positional argument (`install` | `integrate` | `launch` — default `launch`) and works on whatever iOS project the user is currently in. Never ask the user to copy/paste shell commands — execute everything yourself and report what you did.

## Argument parsing

```
/sim-console            → launch (default)
/sim-console launch     → launch the macOS panel
/sim-console install    → ensure repo + binary are present, do nothing else
/sim-console integrate  → wire the SDK into the current iOS project
/sim-console <bundle-id>→ launch against an explicit bundle id (overrides auto-detect)
```

If the argument matches no known sub-command and doesn't look like a bundle id (no dots), treat it as a no-op and print help.

---

## Configuration (single source of truth)

```bash
SIM_LOGS_HOME="${SIM_LOGS_HOME:-$HOME/Developer/sim_logs}"
SIM_CONSOLE_BIN="$SIM_LOGS_HOME/Tools/sim-console"
SIM_CONSOLE_LAUNCHER="$SIM_LOGS_HOME/Tools/sim-console.sh"
SIM_LOGS_REPO="git@github.com:murilloarturo/sim_logs.git"
```

`SIM_LOGS_HOME` is overridable so multiple machines / multiple checkouts can coexist. Default lives under `~/Developer/sim_logs/`.

---

## I — `install` sub-command

Goal: leave `$SIM_LOGS_HOME` with a built `sim-console` binary, ready to launch.

```bash
# 1. Clone if missing
if [ ! -d "$SIM_LOGS_HOME" ]; then
  mkdir -p "$(dirname "$SIM_LOGS_HOME")"
  git clone "$SIM_LOGS_REPO" "$SIM_LOGS_HOME"
fi

# 2. Pull latest (only if on default branch and clean)
cd "$SIM_LOGS_HOME"
if [ -z "$(git status --porcelain)" ] && [ "$(git symbolic-ref --short HEAD)" = "main" ]; then
  git pull --ff-only || true
fi

# 3. Build the macOS binary if missing or stale
if [ ! -x "$SIM_CONSOLE_BIN" ] || [ "$SIM_LOGS_HOME/Tools/sim-console.swift" -nt "$SIM_CONSOLE_BIN" ]; then
  "$SIM_LOGS_HOME/Tools/build.sh"
fi

echo "✓ sim_logs ready at $SIM_LOGS_HOME"
```

If the SSH clone fails (no key configured for the user's GitHub), fall back to HTTPS:
```bash
git clone https://github.com/murilloarturo/sim_logs.git "$SIM_LOGS_HOME"
```

Output a clear message about which clone form succeeded so the user knows the state.

---

## I — `integrate` sub-command

Wire `SimConsole` into the current iOS project (debug builds only). The flow has three steps; check the state of each before acting, and only do what's needed.

### Step 1 — Detect the iOS project layout

Look for **one** of these (in priority order):

1. `project.yml` at the repo root → **XcodeGen**-based project (e.g. Luzia, the DemoApp).
2. `Package.swift` with an iOS-targeting library target → SwiftPM-only project.
3. `*.xcodeproj/project.pbxproj` directly → vanilla Xcode project.

If none, tell the user this doesn't look like an iOS project and stop. Don't try to integrate.

Detect the bundle id from whichever is present:
- XcodeGen: `grep -A 30 "^  LuziaApp-Dev:" project.yml | grep PRODUCT_BUNDLE_IDENTIFIER` (or whatever target stanza is the iOS app).
- Direct Xcode: `grep PRODUCT_BUNDLE_IDENTIFIER *.xcodeproj/project.pbxproj | head -1`.

### Step 2 — Add SimConsole as a Swift Package dependency

**XcodeGen path:**

1. Add to `packages:` section of `project.yml`:
   ```yaml
   packages:
     SimConsole:
       url: https://github.com/murilloarturo/sim_logs
       branch: main
   ```
   If the user's `project.yml` uses `localPackages:` (path-based) for everything else, prefer linking it as a **local** package by cloning to `$SIM_LOGS_HOME` (already done in `install`) and adding:
   ```yaml
   packages:
     SimConsole:
       path: "<relative-path-from-project.yml-to-$SIM_LOGS_HOME>"
   ```
   Use whichever style the rest of the project uses — match the convention.

2. Add to the iOS app target's `dependencies` list:
   ```yaml
       dependencies:
         - package: SimConsole
           embed: true
   ```

3. Regenerate the project:
   ```bash
   xcodegen generate     # or the project's wrapper if there is one
   ```

**Vanilla Xcode path (no XcodeGen):** Use `xcodebuild -resolvePackageDependencies` after editing the `.xcodeproj/project.pbxproj` directly is tricky from a script. Prefer telling the user one line to run: "In Xcode, File → Add Packages → enter `https://github.com/murilloarturo/sim_logs` and add `SimConsole` to your Debug-only target." Then proceed to step 3 once they confirm.

### Step 3 — Add the bootstrap call

Find the app's `@main` entry point. Typical locations:
- `LuziaApp/Core/App/SDKBootstrap.swift` (Luzia-style — a dedicated bootstrap module)
- `<App>App.swift` with `@main struct ...App: App`
- `AppDelegate.swift` with `application(_:didFinishLaunchingWithOptions:)`

Insert at the **earliest possible launch point**, guarded by `#if DEBUG`:

```swift
#if DEBUG
import SimConsole
// ...
SimConsole.bootstrap(.init(
    subsystem: Bundle.main.bundleIdentifier ?? "<bundle-id-fallback>"
))
#endif
```

Use the detected bundle id as the fallback string so the call still works if `Bundle.main.bundleIdentifier` ever returns nil.

### Step 4 — Register the URLProtocol on the URLSession config

Search for `URLSessionConfiguration` factories (e.g. `URLSessionConfigFactory.swift`, `NetworkClient.swift`, anything that does `URLSessionConfiguration.default`). Modify the **central** factory so all URLSessions built from it get the URL protocol:

```swift
#if DEBUG
import SimConsole
// ...
urlSessionConfig.protocolClasses =
    [SimConsoleURLProtocol.self] + (urlSessionConfig.protocolClasses ?? [])
#endif
```

If the project uses **Alamofire** or **Moya**, they ultimately go through `URLSession` — register on the config that gets passed to `Session(configuration:)`. If there's no central factory, ask the user where their URLSession is built and add it there; don't randomly modify every URLSession constructor in the tree.

### Step 5 — (Optional) Add an `AnalyticsReporter` bridge

If the project has a custom analytics protocol (multi-provider setup like Luzia's `AnalyticsMultiplexer`), offer to add a bridge file that wraps each `logEvent` / `logScreenView` and also forwards to `SimConsole.analytics(...)` / `SimConsole.screen(...)`. Otherwise tell the user to call `SimConsole.analytics(...)` directly wherever they fire events.

### Step 6 — Build + verify

```bash
xcodebuild build -workspace <ws>.xcworkspace -scheme <app-scheme> \
  -destination "platform=iOS Simulator,id=<UDID>" 2>&1 | tail -10
```

Confirm it links cleanly. If it fails on "no such module 'SimConsole'", the project regeneration didn't pick up the package — re-run XcodeGen and retry.

---

## I — `launch` sub-command (default)

Goal: spawn the `sim-console` panel beside the booted simulator, targeting the current project's app.

### L1 — Ensure binary is built

Call the `install` sub-command logic first (idempotent — fast no-op if already built).

### L2 — Resolve the target sim

If the user has acquired a sim via sim-lock for this session, use that UDID:

```bash
LOCK_FILE=~/.claude/sim-lock/locks.json
# Find this session's lock if any
if [ -f "$LOCK_FILE" ]; then
  CURRENT_LOCK=$(~/.claude/sim-lock/sim-lock list 2>&1 | grep -B1 "← me" | head -1)
  # If found, derive UDID from the lock list line.
fi
```

Otherwise, fall back to the single booted simulator (`xcrun simctl list devices booted -j` parsing). If multiple booted, ask the user which one or run `sim-lock acquire`.

### L3 — Resolve the bundle id

- If the user passed `<bundle-id>` as argument, use that.
- Otherwise detect from the current project (see `integrate` → Step 1).
- If nothing detected, fall back to asking the user.

### L4 — Confirm app is installed on the sim

```bash
xcrun simctl get_app_container "$SIM_UDID" "$BUNDLE_ID" app 2>/dev/null
```

If not, tell the user to run `/runluzia` (or whatever their launch flow is) first — don't try to install yourself. Stop.

### L5 — Spawn the console

```bash
"$SIM_CONSOLE_LAUNCHER" "$BUNDLE_ID" --device "$SIM_UDID" --level info
```

Default to detached mode (the launcher's default). Pass `--foreground` only if the user explicitly asked for inline streaming.

If a previous `sim-console` process is already running, kill it first:
```bash
pkill -f "sim-console --device" 2>/dev/null
sleep 1
```

Report back which sim + bundle id were chosen so the user can sanity-check.

---

## Killing the console

`pkill sim-console` — or just quit Simulator.app and the console auto-exits.

---

## First-run gotchas

1. **Accessibility prompt.** On the very first launch, macOS prompts for Accessibility permission for the terminal / Claude Code process. The panel won't appear until granted. If `/tmp/sim-console.log` shows `AX trusted: false`, tell the user to grant it in System Settings → Privacy & Security → Accessibility.
2. **SSH key for clone.** If the user has multiple GitHub accounts on the same Mac, `git clone git@github.com:murilloarturo/...` may pick the wrong key. Fall back to HTTPS if SSH fails (see `install`).
3. **Multiple booted sims.** Combine with `sim-lock` to avoid colliding with another concurrent session. Always pass `--device <UDID>` explicitly to the launcher.
4. **Debug builds only.** `SimConsole.bootstrap` should always be inside `#if DEBUG`. Never bootstrap in Release / App Store builds — payloads use `privacy: .public` which would leak in production.

---

## When to use this skill

- "Show me the analytics events from this app" → `/sim-console launch`
- "What network requests is this app making?" → `/sim-console launch`
- "Add sim_logs to this project" → `/sim-console integrate`
- "I want to see what's going on in the app live" → `/sim-console launch`
- "Set up sim-console on this Mac" → `/sim-console install`

If the user asks to "see the logs" in a debugger / Xcode sense, they probably want `/runluzia logs` instead (raw unified log stream). `/sim-console` is for **structured** event viewing.
