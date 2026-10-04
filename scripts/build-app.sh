#!/bin/zsh
# Local, ad-hoc signed universal build. Not a notarised distribution artifact.
set -euo pipefail
cd "${0:A:h:h}"
DERIVED="$PWD/.build/xcode-local"
xcodebuild -project FrankLuma.xcodeproj -scheme FrankLuma -configuration Release \
  -derivedDataPath "$DERIVED" -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  OTHER_CODE_SIGN_FLAGS=--timestamp=none build
mkdir -p dist
ditto "$DERIVED/Build/Products/Release/FrankLuma.app" "$PWD/dist/FrankLuma.app"
codesign --verify --strict "$PWD/dist/FrankLuma.app"
print "Built local sandboxed app: $PWD/dist/FrankLuma.app"
