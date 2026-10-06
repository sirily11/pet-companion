#!/bin/bash
set -euo pipefail
: "${SIGNING_CERTIFICATE_NAME:?SIGNING_CERTIFICATE_NAME is required}"
APP_PATH="${APP_PATH:-output/PetCompanion.xcarchive/Products/Applications/pet-companion.app}"
FRAMEWORK="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
sign() {
  local attempt
  for attempt in 1 2 3; do
    if codesign --force --options runtime --timestamp --sign "$SIGNING_CERTIFICATE_NAME" "$@"; then return; fi
    if [ "$attempt" -lt 3 ]; then sleep 15; fi
  done
  return 1
}
sign "$FRAMEWORK/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$FRAMEWORK/XPCServices/Downloader.xpc"
sign "$FRAMEWORK/Autoupdate"
sign "$FRAMEWORK/Updater.app"
sign "$APP_PATH/Contents/Frameworks/Sparkle.framework"
sign --preserve-metadata=entitlements "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -d --entitlements - --xml "$APP_PATH" 2>/dev/null |
  python3 -c 'import plistlib,sys; e=plistlib.loads(sys.stdin.buffer.read()); assert e.get("com.apple.security.app-sandbox"); assert e.get("com.apple.security.network.client"); assert "com.rxlab.CatCompanion-spki" in e.get("com.apple.security.temporary-exception.mach-lookup.global-name", [])'
