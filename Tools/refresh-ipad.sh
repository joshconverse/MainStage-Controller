#!/bin/bash
# FOH Remote is signed with a free Apple Personal Team, so iOS stops opening it 7 days after it was signed (Apple's
# limit for free teams; a paid Developer Program membership makes it a year). This rebuilds it with a fresh 7-day
# profile and reinstalls it over Wi-Fi. The app's settings on the iPad are kept.
#
#   Tools/refresh-ipad.sh [--device UDID]            renew now
#   Tools/refresh-ipad.sh --if-due [--device UDID]   renew only if it's due (FOH Bridge runs this every 2 hours)
#   Tools/refresh-ipad.sh --enable [--device UDID]   let FOH Bridge keep it renewed (remembers this folder and iPad)
#   Tools/refresh-ipad.sh --disable                  stop that
#   Tools/refresh-ipad.sh --status                   when it expires, and the last result
#
# Due means under 4 days left, FOH Remote not connected to the bridge (an install quits the app), and MainStage not
# running unless under 12 hours are left. The iPad must be paired with this Mac (Xcode › Devices › Connect via
# network) and on the same Wi-Fi. Exit status: 0 renewed or not due, 3 iPad not reachable, 1 anything else.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

BUNDLE_ID=io.itstudios.foh.remote
DOMAIN=io.itstudios.foh.bridge                     # FOH Bridge's defaults: it reads these for its menu
K_REPO=foh.ipadRefresh.repo K_DEVICE=foh.ipadRefresh.device K_EXPIRES=foh.ipadRefresh.expires K_RESULT=foh.ipadRefresh.result
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
LOGDIR="$HOME/Library/Logs"
DD=build/DD-device
APP="$DD/Build/Products/Debug-iphoneos/FOHRemote.app"
DUE_SECONDS=$((4 * 86400))
URGENT_SECONDS=$((12 * 3600))

MODE=now DEVICE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --if-due|--enable|--disable|--status) MODE="${1#--}"; shift ;;
        --device) DEVICE="$2"; shift 2 ;;
        *) echo "unknown option $1" >&2; exit 1 ;;
    esac
done

get() { defaults read "$DOMAIN" "$1" 2>/dev/null || true; }
result() { defaults write "$DOMAIN" "$K_RESULT" -string "$(date '+%a %-d %b %H:%M') - $1"; echo "$1"; }
fmt() { date -j -f %s "$1" '+%a %-d %b, %H:%M'; }

# Expiry of the profile we last installed, as epoch seconds ("" if unknown).
expires_epoch() {
    local e; e=$(get "$K_EXPIRES")
    [[ -n "$e" ]] && date -j -f '%Y-%m-%d %H:%M:%S %z' "$e" +%s 2>/dev/null || true
}

# The first paired physical iPad devicectl knows about.
find_ipad() {
    local json; json=$(mktemp)
    xcrun devicectl list devices --json-output "$json" >/dev/null 2>&1 || true
    /usr/bin/python3 -I - "$json" <<'PY'
import json, sys
try:
    devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception:
    sys.exit(0)
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("deviceType") == "iPad" and hw.get("reality") == "physical" and conn.get("pairingState") == "paired":
        print(hw.get("udid", "")); break
PY
    rm -f "$json"
}

[[ -n "$DEVICE" ]] || DEVICE=$(get "$K_DEVICE")
[[ -n "$DEVICE" ]] || DEVICE=$(find_ipad)

case "$MODE" in
    enable)
        [[ -n "$DEVICE" ]] || { echo "No paired iPad found. Pair it in Xcode › Devices first, or pass --device UDID." >&2; exit 1; }
        defaults write "$DOMAIN" "$K_REPO" -string "$(pwd)"
        defaults write "$DOMAIN" "$K_DEVICE" -string "$DEVICE"
        echo "FOH Bridge will keep FOH Remote renewed on $DEVICE, building from $(pwd)."
        echo "The first time, macOS asks whether FOH Bridge may access your Documents folder: allow it."
        exit 0 ;;
    disable)
        defaults delete "$DOMAIN" "$K_REPO" 2>/dev/null || true
        echo "FOH Bridge won't renew FOH Remote any more."
        exit 0 ;;
    status)
        e=$(expires_epoch)
        echo "Expires: $([[ -n "$e" ]] && fmt "$e" || echo unknown)"
        echo "Last: $(get "$K_RESULT")"
        echo "Renewed by FOH Bridge: $([[ -n "$(get "$K_REPO")" ]] && echo "yes, from $(get "$K_REPO")" || echo no)"
        exit 0 ;;
esac

[[ -n "$DEVICE" ]] || { result "No paired iPad found"; exit 1; }
now=$(date +%s)
expires=$(expires_epoch)
left=$(( ${expires:-0} - now ))

if [[ "$MODE" == "if-due" ]]; then
    if [[ -n "$expires" && $left -gt $DUE_SECONDS ]]; then
        echo "Not due: good until $(fmt "$expires")"; exit 0
    fi
    if lsof -nP -a -c FOHBridge -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep -q ESTABLISHED; then
        echo "Due, but FOH Remote is connected: not interrupting it"; exit 0
    fi
    if pgrep -xq MainStage && [[ -z "$expires" || $left -gt $URGENT_SECONDS ]]; then
        echo "Due, but MainStage is running: waiting${expires:+ (good until $(fmt "$expires"))}"; exit 0
    fi
fi

notify_if_urgent() {
    if [[ -n "$expires" && $left -lt 86400 ]]; then
        local when; when=$([[ $left -gt 0 ]] && echo "expires $(fmt "$expires")" || echo "has expired")
        osascript -e "display notification \"FOH Remote on your iPad $when and couldn't be renewed: $1\" with title \"FOH Remote\"" 2>/dev/null || true
    fi
}

if ! xcrun devicectl device info details --device "$DEVICE" --timeout 30 >/dev/null 2>&1; then
    result "iPad not reachable (asleep, or not on this Wi-Fi); will retry"
    notify_if_urgent "the iPad isn't reachable. Wake it on the same Wi-Fi as this Mac"
    exit 3
fi

# A cached profile would be reused until it expires: remove ours so Xcode issues a fresh 7-day one.
tmp=$(mktemp)
for p in "$PROFILES"/*.mobileprovision; do
    [[ -e "$p" ]] || continue
    security cms -D -i "$p" > "$tmp" 2>/dev/null || continue
    id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$tmp" 2>/dev/null || true)
    [[ "$id" == *".$BUNDLE_ID" ]] && rm -f "$p"
done

[[ -d FOH.xcodeproj ]] || xcodegen generate >/dev/null
mkdir -p "$LOGDIR"
log="$LOGDIR/FOH Remote refresh.log"
echo "Building FOH Remote for $DEVICE…"
if ! xcodebuild -project FOH.xcodeproj -scheme FOHRemote -destination "id=$DEVICE" -derivedDataPath "$DD" \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration build > "$log" 2>&1; then
    reason=$(grep -m1 -E "error:" "$log" | sed 's/.*error: //' | cut -c1-160)
    result "Build failed: ${reason:-see $log}"
    notify_if_urgent "the build failed"
    exit 1
fi
echo "Installing…"
if ! out=$(xcrun devicectl device install app --device "$DEVICE" "$APP" 2>&1); then
    result "Install failed: $(echo "$out" | grep -m1 -iE "error|failed" | cut -c1-160)"
    notify_if_urgent "the install failed"
    exit 1
fi

security cms -D -i "$APP/embedded.mobileprovision" > "$tmp"
new=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$tmp")       # "Sat Nov 21 08:55:32 EST 2026"
rm -f "$tmp"
epoch=$(date -j -f '%a %b %d %T %Z %Y' "$new" +%s)
defaults write "$DOMAIN" "$K_EXPIRES" -date "$(date -u -j -f %s "$epoch" '+%Y-%m-%d %H:%M:%S +0000')"
result "Renewed: good until $(fmt "$epoch")"
