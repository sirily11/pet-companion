#!/bin/bash
set -euo pipefail
: "${SIGNING_CERTIFICATE_NAME:?SIGNING_CERTIFICATE_NAME is required}"
: "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required}"
: "${VERSION:?VERSION is required}"
: "${BUILD_NUMBER:?BUILD_NUMBER is required}"
[[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Use a stable semver version' >&2; exit 1; }
xcodegen generate
xcodebuild -project CatCompanion.xcodeproj -scheme CatCompanion \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath output/PetCompanion.xcarchive -derivedDataPath output/DerivedData \
  ARCHS='arm64' ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$SIGNING_CERTIFICATE_NAME" \
  DEVELOPMENT_TEAM="$APPLE_TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS='--options=runtime --timestamp' \
  MARKETING_VERSION="${VERSION#v}" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" archive
