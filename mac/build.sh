#!/bin/bash
# Builds build/PadLink.app (menu bar host) and signs it with the local identity from make-signing-identity.sh.
# Needs Xcode (swiftc) and libusb (brew install libusb), linked statically.
set -eu
cd "$(dirname "$0")"
APP=build/PadLink.app
KC="$HOME/Library/Keychains/padlink-signing.keychain-db"
USB="$(brew --prefix libusb 2>/dev/null || echo /opt/homebrew/opt/libusb)"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 \
  -import-objc-header Bridging.h -I "$USB/include" \
  Sources/*.swift -o "$APP/Contents/MacOS/PadLink" \
  "$USB/lib/libusb-1.0.a" -lobjc -framework IOKit -framework CoreFoundation -framework Security
cp Info.plist "$APP/Contents/Info.plist"
[ -f "$KC" ] || bash make-signing-identity.sh
security unlock-keychain -p "${PADLINK_KEYCHAIN_PASSWORD:-padlink-local}" "$KC"
codesign --force --keychain "$KC" --sign "PadLink Local Signing" --identifier com.bob.padlink.host "$APP"
codesign -d -r- "$APP" 2>&1 | tail -1
