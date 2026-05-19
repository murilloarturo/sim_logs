#!/usr/bin/env bash
# Compile sim-console: the SwiftUI-based dev console that sits beside a running
# iOS Simulator and renders structured analytics + network rows from JSON
# payloads emitted via SimConsole's os.Logger transport (plus raw text tabs
# for everything else).
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework Cocoa \
  -framework SwiftUI \
  -framework ApplicationServices \
  -o sim-console \
  sim-console.swift
codesign --force --sign - sim-console 2>/dev/null || true
echo "✓ built $(pwd)/sim-console"
