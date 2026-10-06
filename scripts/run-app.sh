#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodegen generate
xcodebuild -project CatCompanion.xcodeproj -scheme CatCompanion -configuration Debug -derivedDataPath build/import-app CODE_SIGN_IDENTITY=- build
open build/import-app/Build/Products/Debug/pet-companion.app
