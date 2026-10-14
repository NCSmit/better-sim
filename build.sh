#!/bin/bash
# Builds build/BetterSim.app. With --install it also replaces ~/Applications/BetterSim.app and relaunches it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/BetterSim.app"
MONITOR="build/BetterSimNetworkMonitor.dylib"

# The network monitor is loaded into simulator apps, so it's built for the iOS simulator rather than the Mac.
mkdir -p build
xcrun -sdk iphonesimulator clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 -mios-simulator-version-min=15.0 \
  -framework Foundation -o "$MONITOR" Monitor/BetterSimNetworkMonitor.m
codesign --force --sign - "$MONITOR"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BetterSim" "$APP/Contents/MacOS/BetterSim"
cp "$MONITOR" "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --sign - "$APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x BetterSim || true
  while pgrep -x BetterSim >/dev/null; do sleep 0.1; done
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/BetterSim.app"
  ditto "$APP" "$HOME/Applications/BetterSim.app"
  open "$HOME/Applications/BetterSim.app"
fi
