#!/bin/bash
set -euo pipefail
: "${APPLE_ID:?APPLE_ID is required}"
: "${APPLE_ID_PWD:?APPLE_ID_PWD is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${SIGNING_CERTIFICATE_NAME:?SIGNING_CERTIFICATE_NAME is required}"
APP_PATH="${APP_PATH:-output/PetCompanion.xcarchive/Products/Applications/pet-companion.app}"
ARCHIVE="${ARCHIVE:-output/PetCompanion.dmg}"
DMG_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pet-dmg.XXXXXX")
trap 'rm -rf "$DMG_DIR"' EXIT
ditto "$APP_PATH" "$DMG_DIR/pet-companion.app"
ln -s /Applications "$DMG_DIR/Applications"
hdiutil create -volname pet-companion -srcfolder "$DMG_DIR" -ov -format UDZO "$ARCHIVE"
codesign --force --timestamp --sign "$SIGNING_CERTIFICATE_NAME" "$ARCHIVE"
# Use a keychain profile when submitting the archive.
PROFILE="pet-companion-${GITHUB_RUN_ID:-local}"
xcrun notarytool store-credentials "$PROFILE" --apple-id "$APPLE_ID" \
  --team-id "$APPLE_TEAM_ID" --password "$APPLE_ID_PWD" --validate
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$ARCHIVE"
xcrun stapler validate "$ARCHIVE"
spctl --assess --type open --context context:primary-signature --verbose=2 "$ARCHIVE"
