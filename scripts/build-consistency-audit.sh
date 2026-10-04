#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/consistency
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
swiftc -parse-as-library -O -target arm64-apple-macosx14.0 -module-cache-path .build/ModuleCache \
  Sources/FrankLuma/{Exposure,Scenes,PatchExposure,SpatialLighting,SpatialRenderer,VideoGeometry,VideoEngine,VideoExporter}.swift \
  scripts/validation/ConsistencyAudit.swift -o .build/consistency/audit
swiftc -parse-as-library -O -module-cache-path .build/ModuleCache scripts/validation/MeasureConsistencyMovie.swift -o .build/consistency/measure
swiftc -module-cache-path .build/ModuleCache scripts/validation/ReadConsistencyImages.swift -o .build/consistency/readpng
swiftc -module-cache-path .build/ModuleCache scripts/validation/ConsistencyContacts.swift -o .build/consistency/contacts
