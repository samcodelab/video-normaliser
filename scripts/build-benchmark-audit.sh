#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
source scripts/correction-sources.sh
mkdir -p .build/benchmark/ModuleCache
swiftc -parse-as-library -O -module-cache-path .build/benchmark/ModuleCache \
 "${CORRECTION_SOURCES[@]}" \
 scripts/validation/BenchmarkAudit.swift -o .build/benchmark/audit
swiftc -parse-as-library -O -module-cache-path .build/benchmark/ModuleCache \
 "${CORRECTION_SOURCES[@]}" \
 scripts/validation/PracticeAudit.swift -o .build/benchmark/real-audit
python3 - <<'PYBUILD'
import hashlib,json,platform,subprocess
from pathlib import Path
root=Path.cwd()
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
sources=sorted((root/'Sources/FrankLuma').rglob('*.swift'))
result={'compiler':subprocess.check_output(['swiftc','--version'],text=True).strip(),
        'platform':platform.platform(),'binarySnapshot':'runner/audit',
        'pipelineSha256':{str(p.relative_to(root)):sha(p) for p in sources},
        'nativeHarnessSha256':sha(root/'scripts/validation/BenchmarkAudit.swift'),
        'binarySha256':sha(root/'.build/benchmark/audit')}
(root/'.build/benchmark/build-provenance.json').write_text(json.dumps(result,indent=2)+'\n')
real={**result,'binarySnapshot':'runner/real-audit',
      'nativeHarnessSha256':sha(root/'scripts/validation/PracticeAudit.swift'),
      'binarySha256':sha(root/'.build/benchmark/real-audit')}
(root/'.build/benchmark/real-build-provenance.json').write_text(json.dumps(real,indent=2)+'\n')
PYBUILD
