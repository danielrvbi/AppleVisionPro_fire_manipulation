#!/bin/zsh
# Build, install and launch FireOpus on the dedicated "Vision Pro Opus" simulator.
# Always targets the simulator by UUID (never `booted`). DerivedData stays inside the project.
# Usage: Tools/run_sim.sh [Debug|Release] [mode]   (mode: livingFlame | flowingRibbon | twoHandArc)
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_UDID="25507330-F20F-4074-889C-4044BD6D44FF"
BUNDLE_ID="dev.elemental.fire.opus"
CONFIG="${1:-Debug}"
MODE="${2:-}"
DERIVED="./DerivedData.nosync"   # .nosync keeps iCloud Desktop sync away from build products

xcodegen generate >/dev/null
# Simulator builds skip bundle signing: iCloud File Provider adds FinderInfo xattrs to .app
# bundles on the Desktop, which codesign rejects. Binaries are still linker ad-hoc signed.
xcodebuild -project FireOpus.xcodeproj -scheme FireOpus -configuration "$CONFIG" \
  -destination "id=$SIM_UDID" -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build \
  | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

APP="$DERIVED/Build/Products/$CONFIG-xrsimulator/FireOpus.app"
xcrun simctl boot "$SIM_UDID" 2>/dev/null || true
xcrun simctl bootstatus "$SIM_UDID" -b >/dev/null
xcrun simctl install "$SIM_UDID" "$APP"
mkdir -p build
if [[ -n "$MODE" ]]; then
  xcrun simctl launch --terminate-running-process "$SIM_UDID" "$BUNDLE_ID" -fireMode "$MODE"
else
  xcrun simctl launch --terminate-running-process "$SIM_UDID" "$BUNDLE_ID"
fi
