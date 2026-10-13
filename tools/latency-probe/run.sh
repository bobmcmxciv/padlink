#!/bin/bash
# End-to-end latency: Mac clock barcode on the tablet's Mac display + tablet clock overlay, read from tablet screenshots.
# Usage: run.sh <adb-serial> <mac-display-id> [samples] [label]
#   mac-display-id: the PadLink display ("virtual display N created" in ~/Library/Logs/PadLink.log),
#                   or any other display that the tablet shows full screen (e.g. an AirPlay display).
# Needs the tablet app (com.bob.padlink) installed; uses $ADB or adb from PATH.
set -eu
SERIAL="$1"; DID="$2"; SAMPLES="${3:-30}"; LABEL="${4:-run}"
ADB="${ADB:-adb}"
D="$(cd "$(dirname "$0")" && pwd)"
APP="$D/build/LatencyProbe.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 "$D/main.swift" -o "$APP/Contents/MacOS/LatencyProbe"
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.bob.padlink.latencyprobe</string><key>CFBundleExecutable</key><string>LatencyProbe</string><key>LSUIElement</key><true/></dict></plist>
PL
codesign -s - -f "$APP" 2>/dev/null
"$ADB" -s "$SERIAL" shell appops set com.bob.padlink SYSTEM_ALERT_WINDOW allow
"$ADB" -s "$SERIAL" shell am broadcast -n com.bob.padlink/.ProbeReceiver --ez show true >/dev/null
open -n "$APP" --args "$DID" 600
sleep 3
ADB="$ADB" python3 "$D/measure.py" "$SERIAL" "$SAMPLES" "$LABEL" || true
"$ADB" -s "$SERIAL" shell am broadcast -n com.bob.padlink/.ProbeReceiver --ez show false >/dev/null
pkill -x LatencyProbe || true
