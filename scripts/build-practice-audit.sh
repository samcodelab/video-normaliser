#!/bin/zsh
# Build native validation tools; does not download footage or change the app.
set -euo pipefail
cd "${0:A:h:h}"
OUTPUT="$PWD/.build/practice"
mkdir -p "$OUTPUT"
swiftc -parse-as-library -O -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$OUTPUT/ModuleCache" \
  Sources/FrankLuma/{Exposure,Scenes,PatchExposure,SpatialLighting,SpatialRenderer,VideoGeometry,VideoEngine,VideoExporter}.swift \
  scripts/validation/PracticeAudit.swift -o "$OUTPUT/audit"
for TOOL in MakePracticeStress MakeLongPractice; do
  swiftc -parse-as-library -O -module-cache-path "$OUTPUT/ModuleCache" \
    "scripts/validation/$TOOL.swift" -o "$OUTPUT/$TOOL"
done
print "Built native practice tools: $OUTPUT"
