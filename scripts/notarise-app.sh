#!/bin/zsh
# Explicit release operation: submits only the supplied app archive to Apple.
# Credentials are read by notarytool from an existing Keychain profile.
set -euo pipefail
if (( $# != 2 )); then
  print -u2 'Usage: scripts/notarise-app.sh /path/to/FrankLuma.app KEYCHAIN_PROFILE'
  exit 2
fi
APP="${1:A}"
PROFILE="$2"
[[ -d "$APP/Contents" ]] || { print -u2 'App bundle not found.'; exit 1; }
codesign --verify --strict "$APP"
DETAILS="$(codesign --display --verbose=4 "$APP" 2>&1)"
[[ "$DETAILS" == *'Authority=Developer ID Application:'* ]] || { print -u2 'A Developer ID Application signature is required.'; exit 1; }
[[ "$DETAILS" == *'(runtime)'* ]] || { print -u2 'Hardened Runtime is required.'; exit 1; }
[[ "$DETAILS" == *'Timestamp='* ]] || { print -u2 'A secure signing timestamp is required.'; exit 1; }
cd "${0:A:h:h}"
mkdir -p .release
OUTPUT="$(mktemp -d "$PWD/.release/notarisation-XXXXXX")"
codesign --display --entitlements - --xml "$APP" > "$OUTPUT/entitlements.plist" 2>/dev/null
python3 - "$OUTPUT/entitlements.plist" <<'PY'
import plistlib,sys
p=plistlib.load(open(sys.argv[1],'rb'))
assert not p.get('com.apple.security.get-task-allow',False), 'Remove the debug entitlement before distribution'
assert p.get('com.apple.security.app-sandbox'), 'Expected FrankLuma sandbox entitlement'
PY
ditto -c -k --keepParent "$APP" "$OUTPUT/submission.zip"
xcrun notarytool submit "$OUTPUT/submission.zip" --keychain-profile "$PROFILE" --wait --output-format json > "$OUTPUT/result.json"
python3 - "$OUTPUT/result.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1]));print('Submission:',r.get('id'),'Status:',r.get('status'))
if r.get('status')!='Accepted':raise SystemExit('Not accepted. Retrieve the notarytool log with this submission ID before distributing.')
PY
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
ditto -c -k --keepParent "$APP" "$OUTPUT/FrankLuma-notarised.zip"
print "Distribution ZIP: $OUTPUT/FrankLuma-notarised.zip"
