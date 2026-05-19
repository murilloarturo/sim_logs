#!/usr/bin/env bash
#
# sim-console.sh — launcher for sim-console.
#
# Discovers the app's process name + display name from its Info.plist on the
# booted simulator, then spawns the SwiftUI panel with predicates for the
# Network / Analytics / Logs / Errors / All tab set. App-agnostic — works for
# any iOS app installed on the simulator.
#
# Usage:
#   sim-console.sh <bundle-id> [options]
#   sim-console.sh --device <UDID> <bundle-id> [options]
#
# Required:
#   <bundle-id>            e.g. com.example.demoapp  (positional)
#
# Options:
#   --device <UDID>        Target sim. Default: the only booted simulator.
#   --width <px>           Console width.    Default: 560
#   --gap <px>             Sim-console gap.  Default: 8
#   --side right|left      Console side.     Default: right
#   --level lvl            log stream level (default | info | debug). Default: info
#   --accent #RRGGBB       Header accent color.
#   --subsystem <id>       Override the App-tab subsystem filter. Default: <bundle-id>
#   --no-default-tabs      Don't add the Network / Analytics / Logs / Errors / All tab set.
#   --tab "<kind>|Name|<NSPredicate>"
#                          Add a custom tab. Repeatable. <kind> ∈ network | analytics | text.
#                          Appended after defaults unless --no-default-tabs is set.
#   --foreground           Run sim-console attached to this terminal (don't detach).
#   -h | --help            Show this help.
#
# Default tab set (when --no-default-tabs is NOT passed):
#   Network    (kind=network)   : subsystem == "<bundle-id>" AND category == "network"
#   Analytics  (kind=analytics) : subsystem == "<bundle-id>" AND category == "analytics"
#   Logs       (kind=text)      : subsystem == "<bundle-id>" AND category == "event"
#   Errors     (kind=text)      : process == "<exe>" AND (messageType == error OR messageType == fault)
#   All        (kind=text)      : process == "<exe>"

set -euo pipefail

print_help() { sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//' | sed '$d'; }

DEVICE=""
BUNDLE_ID=""
WIDTH=560
GAP=8
SIDE="right"
LEVEL="info"
ACCENT=""
SUBSYSTEM=""
USE_DEFAULTS=1
FOREGROUND=0
EXTRA_TABS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device)            DEVICE="$2"; shift 2 ;;
    --width)             WIDTH="$2"; shift 2 ;;
    --gap)               GAP="$2"; shift 2 ;;
    --side)              SIDE="$2"; shift 2 ;;
    --level)             LEVEL="$2"; shift 2 ;;
    --accent)            ACCENT="$2"; shift 2 ;;
    --subsystem)         SUBSYSTEM="$2"; shift 2 ;;
    --no-default-tabs)   USE_DEFAULTS=0; shift ;;
    --tab)               EXTRA_TABS+=("$2"); shift 2 ;;
    --foreground)        FOREGROUND=1; shift ;;
    -h|--help)           print_help; exit 0 ;;
    -*)                  echo "Unknown flag: $1" >&2; print_help; exit 2 ;;
    *)
      if [[ -z "$BUNDLE_ID" ]]; then
        BUNDLE_ID="$1"; shift
      else
        echo "Unexpected positional arg: $1" >&2; exit 2
      fi
      ;;
  esac
done

if [[ -z "$BUNDLE_ID" ]]; then
  echo "Missing <bundle-id>." >&2
  echo "Usage: sim-console.sh <bundle-id> [options]" >&2
  exit 2
fi

# --- Resolve target device ---------------------------------------------------
if [[ -z "$DEVICE" ]]; then
  count=$(xcrun simctl list devices booted -j | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
print(sum(1 for r in data["devices"].values() for d in r))
')
  if [[ "$count" == "0" ]]; then
    echo "No booted simulators. Boot one with xcrun simctl boot <UDID> or pass --device." >&2
    exit 1
  fi
  if [[ "$count" != "1" ]]; then
    echo "Multiple booted simulators — pass --device <UDID>:" >&2
    xcrun simctl list devices booted -j | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data["devices"].values():
    for d in r: print(f"  {d[\"udid\"]}  {d[\"name\"]}")
' >&2
    exit 1
  fi
  DEVICE=$(xcrun simctl list devices booted -j | /usr/bin/python3 -c '
import json, sys
data = json.load(sys.stdin)
for r in data["devices"].values():
    for d in r: print(d["udid"]); sys.exit(0)
')
fi

# --- Resolve sim window title (tag + alt-tag) --------------------------------
CURRENT_NAME=$(xcrun simctl list -j devices | /usr/bin/python3 -c "
import json, sys
data = json.load(sys.stdin)
udid = '$DEVICE'
for runtime in data['devices'].values():
    for d in runtime:
        if d['udid'] == udid:
            print(d['name']); sys.exit(0)
")
if [[ -z "$CURRENT_NAME" ]]; then
  echo "Could not find simulator name for UDID $DEVICE" >&2
  exit 1
fi
ALT_NAME=$(echo "$CURRENT_NAME" | sed -E 's/[[:space:]]+\[[^][]*\][[:space:]]*$//')

# --- Resolve app: process name + display name from Info.plist ----------------
APP_PATH=$(xcrun simctl get_app_container "$DEVICE" "$BUNDLE_ID" app 2>/dev/null || true)
if [[ -z "$APP_PATH" || ! -d "$APP_PATH" ]]; then
  echo "Bundle id '$BUNDLE_ID' is not installed on $DEVICE." >&2
  exit 1
fi
PLIST="$APP_PATH/Info.plist"
PROCESS=$(plutil -extract CFBundleExecutable raw "$PLIST")
DISPLAY_NAME=$(plutil -extract CFBundleDisplayName raw "$PLIST" 2>/dev/null \
              || plutil -extract CFBundleName raw "$PLIST" 2>/dev/null \
              || echo "$PROCESS")

if [[ -z "$SUBSYSTEM" ]]; then
  SUBSYSTEM="$BUNDLE_ID"
fi

# --- Build default tab set ---------------------------------------------------
TABS=()
if [[ "$USE_DEFAULTS" == "1" ]]; then
  TABS+=("network|Network|subsystem == \"$SUBSYSTEM\" AND category == \"network\"")
  TABS+=("analytics|Analytics|subsystem == \"$SUBSYSTEM\" AND category == \"analytics\"")
  TABS+=("text|Logs|subsystem == \"$SUBSYSTEM\" AND category == \"event\"")
  TABS+=("text|Errors|process == \"$PROCESS\" AND (messageType == error OR messageType == fault)")
  TABS+=("text|All|process == \"$PROCESS\"")
fi
if [[ ${#EXTRA_TABS[@]} -gt 0 ]]; then
  for t in "${EXTRA_TABS[@]}"; do
    TABS+=("$t")
  done
fi

if [[ ${#TABS[@]} -eq 0 ]]; then
  echo "No tabs to display. Either don't pass --no-default-tabs or pass at least one --tab." >&2
  exit 2
fi

# --- Build / locate the console binary ---------------------------------------
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/sim-console"
SRC="$HERE/sim-console.swift"
if [[ ! -x "$BIN" ]] || [[ "$SRC" -nt "$BIN" ]]; then
  echo "Building $BIN ..." >&2
  "$HERE/build.sh" >&2
fi

# --- Assemble args -----------------------------------------------------------
APP_LABEL="$DISPLAY_NAME — $BUNDLE_ID"
ARGS=(--device "$DEVICE"
      --tag "$CURRENT_NAME" --alt-tag "$ALT_NAME"
      --app-label "$APP_LABEL"
      --width "$WIDTH" --gap "$GAP" --side "$SIDE"
      --level "$LEVEL")
if [[ -n "$ACCENT" ]]; then ARGS+=(--accent "$ACCENT"); fi
for t in "${TABS[@]}"; do
  ARGS+=(--tab "$t")
done

echo "▸ device : $DEVICE"
echo "▸ app    : $DISPLAY_NAME ($BUNDLE_ID)"
echo "▸ process: $PROCESS"
echo "▸ tabs   : ${#TABS[@]}"
for t in "${TABS[@]}"; do
  IFS='|' read -r KIND NAME _ <<< "$t"
  echo "    • $NAME [$KIND]"
done

if [[ "$FOREGROUND" == "1" ]]; then
  exec "$BIN" "${ARGS[@]}"
else
  nohup "$BIN" "${ARGS[@]}" >/tmp/sim-console.stdout 2>/tmp/sim-console.stderr &
  disown
  echo "▸ console pid: $!  (diagnostic: /tmp/sim-console.log)"
fi
