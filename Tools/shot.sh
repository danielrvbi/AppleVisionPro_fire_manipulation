#!/bin/zsh
# Screenshot the Vision Pro Opus simulator (by UUID) into build/<name>.png plus a 1400px copy,
# and optionally a centre crop (build/<name>_crop.png) for close inspection of the fire.
set -euo pipefail
cd "$(dirname "$0")/.."
SIM_UDID="25507330-F20F-4074-889C-4044BD6D44FF"
NAME="${1:-shot}"
mkdir -p build
xcrun simctl io "$SIM_UDID" screenshot "build/$NAME.png" >/dev/null 2>&1
sips -Z 1400 "build/$NAME.png" --out "build/${NAME}_s.png" >/dev/null
# 1600x1200 crop around the lower-centre region where the fire sits
sips -c 1300 1700 --cropOffset 700 1070 "build/$NAME.png" --out "build/${NAME}_crop.png" >/dev/null
sips -Z 1200 "build/${NAME}_crop.png" >/dev/null
echo "build/${NAME}_s.png build/${NAME}_crop.png"
