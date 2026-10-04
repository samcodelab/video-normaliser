#!/bin/zsh
# Local, ad-hoc signed universal build. Preserve signed distribution artifacts.
set -euo pipefail
cd "${0:A:h:h}"
DERIVED="$PWD/.build/xcode-local"
xcodebuild -project FrankLuma.xcodeproj -scheme FrankLuma -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  OTHER_CODE_SIGN_FLAGS=--timestamp=none build
OUTPUT="$PWD/dist/local/FrankLuma.app"
mkdir -p "${OUTPUT:h}"
STAGING="$(mktemp -d "$PWD/dist/local/build-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$DERIVED/Build/Products/Release/FrankLuma.app" "$STAGING/FrankLuma.app"
codesign --verify --strict "$STAGING/FrankLuma.app"
rm -rf "$OUTPUT"
mv "$STAGING/FrankLuma.app" "$OUTPUT"
print "Built local sandboxed app: $OUTPUT"
