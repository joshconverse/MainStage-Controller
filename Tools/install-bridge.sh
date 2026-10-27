#!/bin/bash
# Install FOH Bridge in /Applications and keep it running: it opens at login and launchd restarts it if it
# crashes (a clean Quit from the menu stays quit). Run again after rebuilding to update the installed copy.
#
#   Tools/install-bridge.sh [path/to/FOHBridge.app]     default: the Xcode build in build/DD-bridge
#   Tools/install-bridge.sh --uninstall                 stop it and remove the login item (the app stays)
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="/Applications/FOH Bridge.app"
LABEL="io.itstudios.foh.bridge.agent"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

stop_bridge() {
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    pkill -TERM -f "Contents/MacOS/FOHBridge" 2>/dev/null || true
    for _ in $(seq 1 20); do
        pgrep -f "Contents/MacOS/FOHBridge" >/dev/null || return 0
        sleep 0.5
    done
    echo "FOH Bridge didn't quit within 10 s" >&2
    exit 1
}

if [[ "${1:-}" == "--uninstall" ]]; then
    stop_bridge
    rm -f "$PLIST"
    echo "Stopped FOH Bridge and removed the login item. The app is still in /Applications."
    exit 0
fi

SRC="${1:-build/DD-bridge/Build/Products/Debug/FOHBridge.app}"
[[ -d "$SRC" ]] || { echo "No app at $SRC. Build the FOHBridge scheme first." >&2; exit 1; }
codesign --verify --deep --strict "$SRC"

stop_bridge
rm -rf "$DEST"
ditto "$SRC" "$DEST"

mkdir -p "$(dirname "$PLIST")"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/FOHBridge</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
PLIST

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed $DEST. It's running now, opens at login, and restarts if it crashes."
