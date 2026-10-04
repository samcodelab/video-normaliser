#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/ModuleCache"
swift build --disable-sandbox -c release -debug-info-format none
BIN_DIR="$(swift build --disable-sandbox -c release --show-bin-path)"
APP="$PWD/dist/Video Normaliser.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VideoNormaliser" "$APP/Contents/MacOS/VideoNormaliser.new"
mv -f "$APP/Contents/MacOS/VideoNormaliser.new" "$APP/Contents/MacOS/VideoNormaliser"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>VideoNormaliser</string>
<key>CFBundleIdentifier</key><string>com.sam.videonormaliser</string>
<key>CFBundleName</key><string>Video Normaliser</string>
<key>CFBundleDisplayName</key><string>Video Normaliser</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>Video</string>
<key>CFBundleTypeRole</key><string>Viewer</string>
<key>LSHandlerRank</key><string>Alternate</string>
<key>LSItemContentTypes</key><array><string>public.movie</string><string>public.video</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
print "Built: $APP"
