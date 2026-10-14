#!/bin/bash
# Renders the README images in docs/ from the real app. It uses the Trails demo app on a throwaway simulator, which
# it deletes afterwards, so nothing from your own simulators or settings appears in the images.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
docs/demo/build-demo.sh

API=""
UDID=$(xcrun simctl create "BetterSim Docs" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)
cleanup() {
  [[ -n "$API" ]] && kill "$API" 2>/dev/null
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID"
}
trap cleanup EXIT

xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
# A new device shows an Apple Intelligence banner about 10 seconds after it boots. Let it come and go first.
sleep 30
xcrun simctl install "$UDID" docs/demo/build/Trails.app
python3 docs/demo/api.py 8765 &
API=$!

BETTERSIM_DOC_IMAGES="$PWD/docs" BETTERSIM_DOC_UDID="$UDID" BETTERSIM_DOC_API="http://127.0.0.1:8765" \
  build/BetterSim.app/Contents/MacOS/BetterSim -AppleLanguages "(en)" -AppleLocale en_US
echo "Images are in docs/"
