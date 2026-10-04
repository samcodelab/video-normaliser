#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/audit '.build/Spatial Final Audit.app/Contents/MacOS'
cp '/Users/sam/Downloads/My_Stop_Motion_Movie(16).mov' .build/audit/source-input.mov
cp '/Users/sam/Downloads/My_Stop_Motion_Movie(16) — Normalised.mov' .build/audit/supplied-input.mov
shasum -a 256 '/Users/sam/Downloads/My_Stop_Motion_Movie(16).mov' '/Users/sam/Downloads/My_Stop_Motion_Movie(16) — Normalised.mov' > .build/audit/spatial-input-hashes.txt
CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache" swiftc \
  -parse-as-library -O -target arm64-apple-macosx14.0 -swift-version 5 \
  -Xfrontend -disable-sandbox -suppress-warnings \
  -module-cache-path "$PWD/.build/ModuleCache" \
  Sources/VideoNormaliser/Exposure.swift Sources/VideoNormaliser/Scenes.swift \
  Sources/VideoNormaliser/PatchExposure.swift Sources/VideoNormaliser/SpatialLighting.swift \
  Sources/VideoNormaliser/SpatialRenderer.swift Sources/VideoNormaliser/VideoGeometry.swift \
  Sources/VideoNormaliser/VideoEngine.swift Sources/VideoNormaliser/VideoExporter.swift \
  scripts/validation/SpatialAudit.swift \
  -o '.build/Spatial Final Audit.app/Contents/MacOS/Audit'
cat > '.build/Spatial Final Audit.app/Contents/Info.plist' <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Audit</string>
<key>CFBundleIdentifier</key><string>com.sam.videonormaliser.spatialfinalaudit</string>
<key>CFBundleName</key><string>Spatial Final Audit</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --sign - '.build/Spatial Final Audit.app'
printf 'Open .build/Spatial Final Audit.app, wait for Complete, then run python3 scripts/validation/summarise_spatial.py\n'
