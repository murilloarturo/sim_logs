---
name: sim-console
description: Install, integrate, and launch sim_logs — a live structured-log overlay that sits beside an iOS Simulator OR Android emulator and renders structured analytics + network + metric rows from an in-app SDK (SimConsole). Use when the user wants to view live analytics events, network requests, or structured logs from an iOS / Android app running on a simulator/emulator, when they say things like "open sim-console", "show me the network logs", "integrate sim_logs into this project", or "install sim-console". Auto-detects iOS vs Android from the current directory. Three sub-commands: `install` (clone repo + build binary + publish Android SDK to Maven Local), `integrate` (wire the SDK into the current iOS or Android project), `launch` (run the macOS panel beside the booted sim/emulator). The skill is the single entry point — never have the user run shell commands by hand.
---

This skill manages **sim_logs** — a developer tool that streams structured analytics, network, and log events from an iOS or Android app onto a SwiftUI panel beside the sim/emulator window. The companion in-app SDKs (`SimConsole` for both platforms) emit JSON envelopes that the macOS app (`sim-console`) renders as typed rows.

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
SIM_CONSOLE_APP="$SIM_LOGS_HOME/Tools/SimConsole.app"
SIM_CONSOLE_LAUNCHER="$SIM_LOGS_HOME/Tools/sim-console.sh"
SIM_LOGS_REPO="git@github.com:murilloarturo/sim_logs.git"
```

`SIM_LOGS_HOME` is overridable so multiple machines / multiple checkouts can coexist. Default lives under `~/Developer/sim_logs/`.

**Note:** SimConsole now ships as a real `.app` bundle (since the USB-device phase). Launch it with `open -n -a "$SIM_CONSOLE_APP" --args …` instead of running a bare binary. `-n` forces a fresh instance so concurrent launches with different `--device` targets don't collide.

---

## P0 — Detect target platform

For `integrate` and `launch`, decide whether the current working directory is an iOS or Android project **before** branching into platform-specific steps. Run this once at the top:

```bash
# iOS markers (any one matches)
IOS_MARKERS=( "project.yml" "Package.swift" "*.xcodeproj" "*.xcworkspace" )
# Android markers (must have both gradle settings + an app module)
ANDROID_SETTINGS=( "settings.gradle.kts" "settings.gradle" )
ANDROID_BUILDS=(   "app/build.gradle.kts" "app/build.gradle" )
```

Priority rules:
1. Both present (very rare — KMP repo) → ask the user which one to target.
2. Only iOS markers → `PLATFORM=ios`.
3. Only Android markers → `PLATFORM=android`.
4. Neither → stop. This isn't a project we know how to integrate.

Save `PLATFORM` and reuse it everywhere downstream.

---

## I — `install` sub-command

Goal: leave `$SIM_LOGS_HOME` with a built `sim-console` binary AND the Android SDK published to the user's Maven Local repo, both ready to launch.

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

# 3. Build the SimConsole.app bundle if missing or stale
APP_EXE="$SIM_CONSOLE_APP/Contents/MacOS/SimConsole"
if [ ! -x "$APP_EXE" ] || [ "$SIM_LOGS_HOME/Tools/sim-console.swift" -nt "$APP_EXE" ]; then
  "$SIM_LOGS_HOME/Tools/build.sh"
fi

# 4. Publish the Android SDK to ~/.m2 so Gradle consumers can pick it up
#    via `mavenLocal()` + implementation("com.simconsole:simconsole:0.1.0").
#    Skip if the AAR is already there and newer than any source file.
M2_AAR="$HOME/.m2/repository/com/simconsole/simconsole/0.1.0/simconsole-0.1.0.aar"
NEWEST_SRC=$(find "$SIM_LOGS_HOME/android/simconsole/src" -name "*.kt" -newer "$M2_AAR" 2>/dev/null | head -1)
if [ ! -f "$M2_AAR" ] || [ -n "$NEWEST_SRC" ]; then
  ( cd "$SIM_LOGS_HOME/android" && ./gradlew :simconsole:publishToMavenLocal --console=plain --no-daemon )
fi

echo "✓ sim_logs ready at $SIM_LOGS_HOME"
echo "  panel app:    $SIM_CONSOLE_APP"
echo "  android SDK:  com.simconsole:simconsole:0.1.0 (Maven Local)"

# 5. (Optional but recommended) install idevicesyslog so we can stream
#    logs from a USB-connected iPhone. Only install if Homebrew is present;
#    fall through silently if not.
if ! command -v idevicesyslog >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install libimobiledevice 2>&1 | tail -5
    echo "  idevicesyslog: installed via Homebrew"
  else
    echo "  idevicesyslog: not installed (only needed for USB iPhone support)"
  fi
fi
```

If the SSH clone fails (no key configured for the user's GitHub), fall back to HTTPS:
```bash
git clone https://github.com/murilloarturo/sim_logs.git "$SIM_LOGS_HOME"
```

Output a clear message about which clone form succeeded so the user knows the state.

---

## I — `integrate` sub-command

Wire `SimConsole` into the current project (debug builds only). Branch on `PLATFORM` from the P0 detection step. The iOS flow is **Section iOS-I** below; the Android flow is **Section ANDROID-I**.

---

## Section ANDROID-I — `integrate` on Android

### A1 — Detect the Android project layout

Confirm there's a top-level `settings.gradle{,.kts}` and at least one module with `applicationId` (typically `app/`). Extract the package id:

```bash
APP_GRADLE=$(ls app/build.gradle.kts app/build.gradle 2>/dev/null | head -1)
# applicationId can be a literal or a property reference. Handle both:
APPLICATION_ID=$(grep -E '^\s*applicationId\s*=\s*"' "$APP_GRADLE" \
  | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
# If empty, fall back to namespace + variant suffix, or ask the user.
```

If the app module is named something other than `app/`, look at `settings.gradle.kts` for `include(":<name>")` declarations and find the one whose `build.gradle{,.kts}` declares `id("com.android.application")`.

### A2 — Add the SimConsole dependency

Two edits, both narrow:

**1. Add `mavenLocal()` to the repos** in `settings.gradle.kts` (or the root `build.gradle.kts` if that's where `repositories {}` lives). Most projects already have `mavenLocal()` listed; if so, skip.

```kotlin
// settings.gradle.kts (dependencyResolutionManagement block)
repositories {
    google()
    mavenCentral()
    mavenLocal()    // ← add
}
```

**2. Add a `debugImplementation` dependency** to the app module:

```kotlin
// app/build.gradle.kts
dependencies {
    debugImplementation("com.simconsole:simconsole:0.1.0")
}
```

`debugImplementation` keeps the SDK out of release builds entirely — there's no `#if DEBUG` equivalent in Kotlin/Android, so we rely on build-variant scoping. If the project uses a different debuggable variant (e.g. `staging`), prefer the matching `<variant>Implementation` configuration.

### A3 — Add the bootstrap call

Find or create the `Application` subclass. Two cases:

**Case 1 — existing Application subclass.** Look in `AndroidManifest.xml`:
```xml
<application android:name=".MyApp" ...>
```
Open the named class and add to `onCreate()`:
```kotlin
import com.simconsole.SimConsole

override fun onCreate() {
    super.onCreate()
    if (BuildConfig.DEBUG) {
        SimConsole.bootstrap(this, subsystem = BuildConfig.APPLICATION_ID)
    }
    // ... rest of existing onCreate
}
```

**Case 2 — no Application subclass.** Create one in `app/src/main/java/<package>/SimConsoleApp.kt`:
```kotlin
package <package>

import android.app.Application
import com.simconsole.SimConsole

class SimConsoleApp : Application() {
    override fun onCreate() {
        super.onCreate()
        if (BuildConfig.DEBUG) {
            SimConsole.bootstrap(this, subsystem = BuildConfig.APPLICATION_ID)
        }
    }
}
```
And register it in `AndroidManifest.xml`:
```xml
<application android:name=".SimConsoleApp" ...>
```

Use `applicationContext` implicitly — `this` inside `Application.onCreate` is already the app context.

### A4 — Wire SimConsoleInterceptor into OkHttp

Search for `OkHttpClient.Builder()`:
```bash
grep -rn "OkHttpClient.Builder()" app/src/main --include="*.kt"
```

The right place is the **central** factory that builds the client used by Retrofit / Ktor / direct `Call.execute()`. Add the interceptor:

```kotlin
import com.simconsole.SimConsoleInterceptor

val client = OkHttpClient.Builder()
    .apply { if (BuildConfig.DEBUG) addInterceptor(SimConsoleInterceptor()) }
    // ... existing interceptors
    .build()
```

Place this **last** so it sees retry-final requests but before any compression interceptor that might mangle the body. If the project uses **Retrofit** or **Ktor with OkHttp engine**, both surface the same client — wire it once at the OkHttp layer.

If there's no central factory and the client is built ad-hoc in multiple places, ask the user where to wire it; don't blindly modify every constructor.

### A5 — Build + verify

```bash
./gradlew :app:assembleDebug --console=plain 2>&1 | tail -20
```

If it fails with `Could not resolve com.simconsole:simconsole:0.1.0`, the Android SDK wasn't published — re-run `/sim-console install` which now also publishes to Maven Local.

If `BuildConfig.DEBUG` is unresolved, the consumer's variant doesn't generate `BuildConfig` — replace with a literal `true` (the dependency is already debug-scoped via `debugImplementation`).

---

## Section iOS-I — `integrate` on iOS

The flow has three steps; check the state of each before acting, and only do what's needed.

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

Goal: spawn the `sim-console` panel beside the booted simulator/emulator, targeting the current project's app. Branch on `PLATFORM`.

### L1 — Ensure binary is built (both platforms)

Call the `install` sub-command logic first (idempotent — fast no-op if already built). On Android this also ensures the SDK is in Maven Local in case the user is launching for the first time on a freshly-checked-out machine.

---

## Section ANDROID-L — `launch` on Android

### A-L2 — Resolve the target device (emulator or USB)

```bash
# Pick the first attached emulator OR USB device.
# Format: "<serial>\tdevice" — emulators have "emulator-NNNN", USB phones have a hex serial.
SERIAL=$(adb devices | awk '/\tdevice$/ { print $1; exit }')
if [ -z "$SERIAL" ]; then
  echo "No Android device or emulator attached. Start an emulator with"
  echo "  emulator -avd <name>"
  echo "or plug in a phone with USB debugging enabled."
  exit 1
fi

# Detached mode is required for USB devices (no on-screen device window to dock to).
if [[ "$SERIAL" == emulator-* ]]; then
  DETACHED_FLAG=""
else
  DETACHED_FLAG="--detached"
fi
```

If multiple devices are attached, ask the user which one — we don't have an Android equivalent of `sim-lock` yet. Tell the user whether you picked an emulator (docked panel) or USB device (detached panel) so they can sanity-check.

### A-L3 — Resolve the package id

- If the user passed `<bundle-id>` as argument, use that.
- Otherwise re-run the A1 detection (`grep applicationId app/build.gradle{,.kts}`).
- Fall back to asking the user.

### A-L4 — Confirm app is installed on the emulator

```bash
adb -s "$SERIAL" shell pm list packages "$APPLICATION_ID" | grep -q "$APPLICATION_ID"
```

If not, tell the user to `./gradlew :app:installDebug` (or run via Android Studio) first — don't try to install yourself.

### A-L5 — Spawn the panel

```bash
open -n -a "$SIM_CONSOLE_APP" --args \
  --platform android \
  --device "$SERIAL" \
  --tag "Android Emulator" \
  --bundle-id "$APPLICATION_ID" \
  --width 560 --gap 8 --side right \
  $DETACHED_FLAG \
  --tab "metric|Metrics|SimConsole.metric:V SimConsole.metric.chunk:V *:S" \
  --tab "network|Network|SimConsole.network:V SimConsole.network.chunk:V *:S" \
  --tab "analytics|Analytics|SimConsole.analytics:V SimConsole.analytics.chunk:V *:S" \
  --tab "text|Logs|SimConsole.event:V SimConsole.event.chunk:V *:S" \
  --tab "text|Errors|*:E *:F" \
  --tab "text|All|*:V"
```

Notes:
- The `--tag "Android Emulator"` argument is accepted for symmetry with the iOS path but unused on Android — the panel docks against the qemu window via `CGWindowListCopyWindowInfo` (emulators) or floats freely (USB devices, via `--detached`).
- Each `--tab` for Android takes a **logcat filterspec** as the third pipe-separated field (not an NSPredicate). The `*:S` suffix silences everything else; omit it for the All/Errors tabs which want to see other tags.
- `--bundle-id` enables MockSync — the panel will `adb push` `~/.sim-console/mocks-<pkg>.json` to `/data/local/tmp/` on every mock edit.
- `--detached` (auto-appended for USB devices) makes the panel a user-draggable floating window. Position persists at `~/.sim-console/panel-frame-<pkg>.json` across runs. Lifecycle switches to `adb -s <serial> get-state` polling — panel exits when the device disconnects.

Kill any previous panel first:
```bash
pkill -f "sim-console --platform" 2>/dev/null
sleep 1
```

Report back which emulator + package id were chosen so the user can sanity-check.

---

## Section iOS-L — `launch` on iOS

### L2 — Resolve the target sim *or* USB device

The user may want to stream from either a booted simulator or a USB-connected iPhone.

**Probe for a connected iPhone first:**

```bash
# Returns a non-empty UDID if an iPhone is plugged in and paired.
IOS_UDID=$(xcrun devicectl list devices --json-output /tmp/devicectl-devices.json --quiet 2>/dev/null \
  && python3 -c "
import json
with open('/tmp/devicectl-devices.json') as f: data = json.load(f)
for d in data.get('result', {}).get('devices', []):
    conn = d.get('connectionProperties', {})
    name = d.get('deviceProperties', {}).get('name', '')
    if conn.get('tunnelState') == 'connected' and 'iPhone' in d.get('hardwareProperties', {}).get('productType', ''):
        print(d['identifier'])
        break
")
```

**Disambiguate:**
- If the user passed `realDevice` / `device` / `iphone` as an argument, prefer the iPhone.
- If no iPhone is connected, fall back to the simulator path (sim-lock acquire, single booted sim, etc.).
- If both are available and the user didn't specify, ask which to target.

When picking the iPhone path, also resolve `idevicesyslog` (Homebrew-installed):

```bash
which idevicesyslog >/dev/null || brew install libimobiledevice
IDEVICESYSLOG_PATH=$(which idevicesyslog)
```

### L2.5 (USB device path only) — Install the iOS app on the phone before opening SimConsole

Cold-flow for a connected iPhone is: **build → install on device → open SimConsole pointing at it**. The user shouldn't have to fall back to Xcode just to side-load the app.

Detect the host project's preferred device-install path in this order:

1. **Project-specific skill** — if the current repo has `/runluzia realDevice` (or any project-defined "run on physical device" command), delegate to it. Cleanest path because the project owns its scheme + signing config.

2. **`xcodebuild` build for device + `xcrun devicectl device install`** — generic fallback. Run from the repo root:
   ```bash
   xcodebuild -workspace <ws>.xcworkspace -scheme <scheme> \
     -configuration Debug \
     -destination "platform=iOS,id=$IOS_UDID" \
     -derivedDataPath /tmp/sim-logs-derived \
     build 2>&1 | tail -5

   APP_PATH=$(find /tmp/sim-logs-derived/Build/Products/Debug-iphoneos -maxdepth 1 -name "*.app" -type d | head -1)
   xcrun devicectl device install app --device "$IOS_UDID" "$APP_PATH"
   ```

3. **Manual**: if neither works, tell the user "I couldn't auto-install — install the app via Xcode first, then re-run `/sim-console launch`."

After install succeeds, the iOS app needs to be running for events to flow. Either:
- Let the user tap the app on the phone, or
- `xcrun devicectl device process launch --device "$IOS_UDID" --terminate-existing "$BUNDLE_ID"`

Then continue to step L5 (USB-device variant) to open SimConsole. Otherwise — for a simulator target — continue with the simulator flow below.

### L2 (simulator path) — Resolve the target sim

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

**For an iOS Simulator target:**
```bash
open -n -a "$SIM_CONSOLE_APP" --args \
  --platform ios \
  --device "$SIM_UDID" \
  --tag "$SIM_NAME" \
  --bundle-id "$BUNDLE_ID" \
  --width 560 --gap 8 --side right --level info \
  --tab "metric|Metrics|subsystem == \"$BUNDLE_ID\" AND category == \"metric\"" \
  --tab "network|Network|subsystem == \"$BUNDLE_ID\" AND category == \"network\"" \
  --tab "analytics|Analytics|subsystem == \"$BUNDLE_ID\" AND category == \"analytics\"" \
  --tab "text|Logs|subsystem == \"$BUNDLE_ID\" AND category == \"event\"" \
  --tab "text|Errors|subsystem == \"$BUNDLE_ID\" AND (messageType == \"error\" OR messageType == \"fault\")" \
  --tab "text|All|subsystem == \"$BUNDLE_ID\""
```

The simulator path opens *attached* — the panel snaps next to the Simulator window via Accessibility-API lookup and tracks it. Click the **Detach** button in the header to free the panel; click **Attach** to snap it back.

**For a USB-connected iPhone target:**
```bash
open -n -a "$SIM_CONSOLE_APP" --args \
  --platform ios --detached \
  --device "$IOS_UDID" \
  --bundle-id "$BUNDLE_ID" \
  --idevicesyslog-path "$IDEVICESYSLOG_PATH" \
  --width 560 --gap 8 --side right \
  --tab "metric|Metrics|subsystem == \"$BUNDLE_ID\" AND category == \"metric\"" \
  --tab "network|Network|subsystem == \"$BUNDLE_ID\" AND category == \"network\"" \
  --tab "analytics|Analytics|subsystem == \"$BUNDLE_ID\" AND category == \"analytics\"" \
  --tab "text|Logs|subsystem == \"$BUNDLE_ID\" AND category == \"event\"" \
  --tab "text|Errors|subsystem == \"$BUNDLE_ID\" AND (messageType == \"error\" OR messageType == \"fault\")" \
  --tab "text|All|subsystem == \"$BUNDLE_ID\""
```

Notes for the USB-device path:
- `idevicesyslog` (from libimobiledevice) replaces `xcrun simctl spawn log stream` — `devicectl` doesn't have a log-stream subcommand. The panel auto-discovers it under `/opt/homebrew/bin/` or `/usr/local/bin/`.
- `--detached` makes the panel a movable floating window (no on-screen iPhone window to dock against). Position persists at `~/.sim-console/panel-frame-<bundle>.json`.
- Lifecycle: panel polls `xcrun devicectl list devices` once per tick — exits when the iPhone disconnects.
- Mock sync: panel pushes mock-file changes via `xcrun devicectl device copy to --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" --source <local> --destination Documents/sim-console/mocks.json` (~hundreds of ms per push, vs near-zero on simulator).
- **Requires iOS 17+ on the device** for the Core Device tunnel that backs `devicectl`.

If a previous `sim-console` process is already running, kill it first:
```bash
pkill -f "sim-console --device" 2>/dev/null
sleep 1
```

Report back which sim/device + bundle id were chosen so the user can sanity-check.

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

- "Show me the analytics events from this app" → `/sim-console launch` (iOS or Android — auto-detects)
- "What network requests is this Android app making?" → `/sim-console launch`
- "Add sim_logs to this iOS / Android project" → `/sim-console integrate`
- "I want to see what's going on in the app live" → `/sim-console launch`
- "Set up sim-console on this Mac" → `/sim-console install`

If the user asks to "see the logs" in a debugger / Xcode / Android Studio sense, they probably want raw `xcrun simctl spawn ... log stream` or `adb logcat` directly. `/sim-console` is for **structured** event viewing of JSON envelopes emitted by the SimConsole SDK.

---

## Companion: MCP server (for agentic queries)

`sim-console` also writes every captured event to `~/.sim-console/events.jsonl` (overridable via `SIM_CONSOLE_EXPORT` or `--export-to`). A small MCP server in `Tools/mcp-server/` reads that file and exposes query tools to Claude:

- `mcp__sim_logs__list_recent_requests(filter, status_min, status_max, method, limit)`
- `mcp__sim_logs__get_request(id)`
- `mcp__sim_logs__list_recent_analytics(filter, kinds, since_seconds, limit)`
- `mcp__sim_logs__list_recent_logs(filter, levels, since_seconds, limit)`
- `mcp__sim_logs__stats()`
- `mcp__sim_logs__clear()`

Install once on the user's machine with `~/Developer/sim_logs/Tools/install-mcp.sh` (requires `uv` and the `claude` CLI). The tools surface in any **new** Claude Code session — existing sessions need to reload to pick them up.

When **should** you use the MCP tools instead of the visual panel?
- The panel is for the **human** to glance at while they tap.
- The MCP tools are for the **agent** to introspect: "what status did the /profile request return?", "did the share button fire the share_event?", "show me errors in the last 60s". Use the MCP path during automated debugging or test-loop scenarios where the agent needs to *read* what the app emitted, not just display it for the user.

Both share the same in-memory event source — neither blocks the other.
