#!/bin/bash
# Build build/JarvisSwitch.app from source. Needs the Xcode Command Line Tools (swiftc).
#   scripts/build.sh            -> build/JarvisSwitch.app
#   scripts/build.sh /some/dir  -> /some/dir/JarvisSwitch.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build}"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$OUT/JarvisSwitch.app"
GEN="$(mktemp -d)"
trap 'rm -rf "$GEN"' EXIT
printf 'let appVersion = "%s"\n' "$VERSION" > "$GEN/Version.swift"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos13.0" \
  -o "$APP/Contents/MacOS/JarvisSwitch" "$ROOT"/Sources/*.swift "$GEN/Version.swift" -framework Cocoa -framework SwiftUI
sed "s/__VERSION__/$VERSION/g" "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1 || true
echo "$APP"
