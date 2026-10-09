#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/correction-sources.sh
CORRECTION_SOURCES=( ${CORRECTION_SOURCES:#*SpatialLighting.swift} )
mkdir -p .build/matched-surface-audit
# Keep descriptor access private in production. The diagnostic shares file scope.
cat Sources/FrankLuma/Core/Correction/SpatialLighting.swift scripts/validation/MatchedSurfaceAudit.swift > .build/matched-surface-audit/Combined.swift
swiftc -parse-as-library -O -module-cache-path .build/benchmark/ModuleCache \
 "${CORRECTION_SOURCES[@]}" \
 .build/matched-surface-audit/Combined.swift -o .build/matched-surface-audit/audit
python3 - <<'PY'
import hashlib,json
from pathlib import Path
sources=[Path('scripts/validation/MatchedSurfaceAudit.swift'),*Path('Sources/FrankLuma').rglob('*.swift')]
result={'sources':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
        'binarySha256':hashlib.sha256(Path('.build/matched-surface-audit/audit').read_bytes()).hexdigest()}
Path('.build/matched-surface-audit/provenance.json').write_text(json.dumps(result,indent=2)+'\n')
PY
