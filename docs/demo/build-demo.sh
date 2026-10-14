#!/bin/bash
# Builds the Trails demo app for the iOS simulator. It's only used to make BetterSim's README images.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Trails.app"
rm -rf build
mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc -parse-as-library -O -target arm64-apple-ios17.0-simulator \
  Trails/TrailsApp.swift -o "$APP/Trails"
cp Trails/Info.plist "$APP/Info.plist"
swift icon.swift "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"
