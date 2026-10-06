#!/bin/bash
set -euo pipefail
: "${SPARKLE_KEY:?SPARKLE_KEY is required}"
: "${VERSION:?VERSION is required}"
: "${BUILD_NUMBER:?BUILD_NUMBER is required}"
[[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Only stable semver releases can publish updates' >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPARKLE_BIN="${SPARKLE_BIN:-output/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin}"
APP_PATH="${APP_PATH:-output/PetCompanion.xcarchive/Products/Applications/pet-companion.app}"
ARCHIVE="${ARCHIVE:-output/PetCompanion.dmg}"
PAGES_DIR="${PAGES_DIR:-output/pages}"
DOWNLOAD_PREFIX="https://github.com/${GITHUB_REPOSITORY:-sirily11/pet-companion}/releases/download/$VERSION/"
WORK_DIR=$(mktemp -d "${RUNNER_TEMP:-/tmp}/pet-appcast.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$PAGES_DIR"
cp "$ARCHIVE" "$WORK_DIR/PetCompanion.dmg"
printf '%s' "${RELEASE_NOTE:-}" > "$WORK_DIR/notes.txt"
python3 - "$WORK_DIR" <<'PY'
import html, pathlib, sys
p=pathlib.Path(sys.argv[1])
notes=html.escape((p/'notes.txt').read_text())
(p/'PetCompanion.html').write_text('<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>pet-companion release notes</title><style>:root{color-scheme:light dark}body{font:15px system-ui;max-width:700px;margin:32px auto;padding:0 20px}pre{white-space:pre-wrap;font:inherit;line-height:1.6}</style><h1>pet-companion</h1><pre>'+notes+'</pre></html>')
PY
printf '%s' "$SPARKLE_KEY" | "$SPARKLE_BIN/generate_appcast" "$WORK_DIR" \
  --ed-key-file - --maximum-deltas 0 \
  --link "https://github.com/${GITHUB_REPOSITORY:-sirily11/pet-companion}/releases/tag/$VERSION" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --release-notes-url-prefix 'https://update.pet.rxlab.app/'
python3 "$SCRIPT_DIR/validate-appcast.py" "$WORK_DIR/appcast.xml" "$ARCHIVE" \
  "$APP_PATH/Contents/Info.plist" "$DOWNLOAD_PREFIX"
cp update-site/index.html update-site/CNAME update-site/.nojekyll "$PAGES_DIR/"
cp "$WORK_DIR/appcast.xml" "$WORK_DIR/PetCompanion.html" "$PAGES_DIR/"
