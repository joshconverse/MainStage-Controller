#!/bin/bash
# Build FOH Meter, the Audio Unit you insert on a MainStage strip (an FX return) so the iPad can meter it, and install
# it in ~/Library/Audio/Plug-Ins/Components. MainStage lists it under Audio Units › FOH Remote after it next starts.
#
#   Tools/install-meter.sh               build (Release, universal) and install
#   Tools/install-meter.sh --uninstall   remove it
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

DEST="$HOME/Library/Audio/Plug-Ins/Components/FOH Meter.component"
rescan() { killall -9 AudioComponentRegistrar 2>/dev/null || true; }   # macOS re-reads the components folder

if [[ "${1:-}" == "--uninstall" ]]; then
    rm -rf "$DEST"
    rescan
    echo "Removed FOH Meter. Strips that use it show it as missing in MainStage until you take it out."
    exit 0
fi

xcodebuild -project FOH.xcodeproj -scheme FOHMeter -configuration Release -destination "generic/platform=macOS" \
    -derivedDataPath build/DD-meter \
    -allowProvisioningUpdates -quiet build
SRC="build/DD-meter/Build/Products/Release/FOH Meter.component"
codesign --verify --strict "$SRC"

mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
rescan
if auval -v aufx FMtr FOHr | grep -q "AU VALIDATION SUCCEEDED"; then
    echo "Installed $DEST (passes auval)."
else
    echo "Installed $DEST, but auval failed: run  auval -v aufx FMtr FOHr  to see why." >&2
    exit 1
fi
if pgrep -xq MainStage; then
    echo "MainStage is running: quit and reopen it to see FOH Meter in the plug-in menu."
fi
echo "In MainStage, insert Audio Units › FOH Remote › FOH Meter as the last plugin on each strip to meter (e.g. VRB Return)."
