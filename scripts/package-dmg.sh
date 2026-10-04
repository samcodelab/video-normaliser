#!/bin/zsh
# Package an already-notarised app, sign and notarise the DMG, then publish locally.
set -euo pipefail
if (( $# != 2 )); then
  print -u2 'Usage: scripts/package-dmg.sh /path/to/FrankLuma.app KEYCHAIN_PROFILE'
  exit 2
fi
APP="${1:A}"
PROFILE="$2"
cd "${0:A:h:h}"
codesign --verify --strict "$APP"
xcrun stapler validate "$APP"
DETAILS="$(codesign --display --verbose=4 "$APP" 2>&1)"
IDENTITY="$(print -r -- "$DETAILS" | sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p')"
[[ -n "$IDENTITY" ]] || { print -u2 'Developer ID Application signature required'; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"
OUTPUT="$(mktemp -d "$PWD/.release/dmg-XXXXXX")"
mkdir -p "$OUTPUT/staging" "$PWD/dist"
ditto "$APP" "$OUTPUT/staging/FrankLuma.app"
ln -s /Applications "$OUTPUT/staging/Applications"
cat > "$OUTPUT/staging/Install.txt" <<EOF
FrankLuma $VERSION (build $BUILD)

Drag FrankLuma to Applications, then open it from Applications.
Requires macOS 14 or later. Supports Apple silicon and Intel Macs.

Choose Help > Open Demo Video to try the included sample.
SDR video only, up to 4096 pixels per side. Output: H.264 QuickTime (.mov).
Editing sessions are not saved as projects; export your corrected video before leaving.

Support: support@broadframestudio.com
EOF
DMG="$OUTPUT/FrankLuma-$VERSION-build-$BUILD.dmg"
hdiutil create -volname FrankLuma -srcfolder "$OUTPUT/staging" -format UDZO -fs HFS+ "$DMG"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait --output-format json > "$OUTPUT/notarisation.json"
python3 - "$OUTPUT/notarisation.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));print('DMG submission:',r.get('id'),'Status:',r.get('status'))
if r.get('status')!='Accepted':raise SystemExit('DMG was not accepted. Retrieve the notarytool log before distribution.')
PY
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
hdiutil verify "$DMG"
FINAL="$PWD/dist/${DMG:t}"
[[ ! -e "$FINAL" ]] || { print -u2 "Already exists: $FINAL. Verified new DMG remains at $DMG"; exit 1; }
cp "$DMG" "$FINAL"
shasum -a 256 "$FINAL" > "$FINAL.sha256"
print "Ready for distribution: $FINAL"
