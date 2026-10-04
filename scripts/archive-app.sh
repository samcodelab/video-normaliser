#!/bin/zsh
# Build a signed archive and export it. Does not upload to Apple.
set -euo pipefail
cd "${0:A:h:h}"
CHANNEL="${1:-developer-id}"
PROVISIONING_ARGS=()
if [[ "${2:-}" == --allow-provisioning-updates ]]; then
  PROVISIONING_ARGS=(-allowProvisioningUpdates)
elif [[ -n "${2:-}" ]]; then
  print -u2 'Usage: scripts/archive-app.sh [developer-id|app-store] [--allow-provisioning-updates]'
  exit 2
fi
case "$CHANNEL" in
  developer-id) SCHEME='FrankLuma Developer ID'; OPTIONS='Configuration/DeveloperIDExportOptions.plist' ;;
  app-store) SCHEME='FrankLuma App Store'; OPTIONS='Configuration/AppStoreExportOptions.plist' ;;
  *) print -u2 'Usage: scripts/archive-app.sh [developer-id|app-store]'; exit 2 ;;
esac
STAMP="$(date +%Y%m%d-%H%M%S)"
OUTPUT="$PWD/.release/$CHANNEL-$STAMP"
mkdir -p "$OUTPUT"
xcodebuild -project FrankLuma.xcodeproj -scheme "$SCHEME" \
  -destination 'generic/platform=macOS' -derivedDataPath "$PWD/.build/xcode-release" \
  -archivePath "$OUTPUT/FrankLuma.xcarchive" "${PROVISIONING_ARGS[@]}" archive
if [[ "$CHANNEL" == app-store ]]; then
  python3 scripts/verify-store-archive.py "$OUTPUT/FrankLuma.xcarchive"
fi
xcodebuild -exportArchive -archivePath "$OUTPUT/FrankLuma.xcarchive" \
  -exportOptionsPlist "$OPTIONS" -exportPath "$OUTPUT/export" "${PROVISIONING_ARGS[@]}"
if [[ "$CHANNEL" == developer-id ]]; then
  codesign --verify --strict "$OUTPUT/export/FrankLuma.app"
  codesign --display --verbose=4 "$OUTPUT/export/FrankLuma.app"
fi
print "Exported: $OUTPUT/export"
print 'No upload or notarisation has been performed.'
