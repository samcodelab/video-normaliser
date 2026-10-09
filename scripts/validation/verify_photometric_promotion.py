"""Require completed immutable candidate evidence and exact source equivalence."""
import hashlib
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
FOLDER=ROOT/'.build/review-v31/photometric-confidence-experiment'
OUT=ROOT/'dist/Benchmarks/general-review-v30'
sweep=json.loads((OUT/'photometric-confidence-slider-sweep.json').read_text())
assert sweep['complete'] and sweep['completedEncodedCases']==450 and not sweep['pendingProfiles']
provenance=json.loads((FOLDER/'runner/build-provenance.json').read_text())
verified={}
for filename,expected in provenance['pipelineSha256'].items():
    data=(ROOT/filename).read_bytes()
    if filename.endswith('/SpatialLighting.swift'):
        # The only permitted promotion difference is the opt-in default.
        before=b'contrastTrackingEnabled = ProcessInfo.processInfo.environment["FRANKLUMA_CONTRAST_TRACKING"] == "1"'
        after=b'contrastTrackingEnabled = ProcessInfo.processInfo.environment["FRANKLUMA_CONTRAST_TRACKING"] != "0"'
        assert data.count(before)+data.count(after)==1
        data=data.replace(after,before)
    assert hashlib.sha256(data).hexdigest()==expected, filename
    verified[filename]=hashlib.sha256((ROOT/filename).read_bytes()).hexdigest()
review=json.loads((OUT/'photometric-confidence-review.json').read_text())
assert review['nativeTestsPassed']==144
assert len(review['realCases'])==5 and all(x['integrity']['passed'] for x in review['realCases'])
assert len(review['foxSliderTrials'])==3 and all(x['integrity']['passed'] for x in review['foxSliderTrials'])
result={'candidateBinarySha256':provenance['binarySha256'],'currentSourceSha256':verified,
        'sliderCases':450,'realExports':5,'foxSliderExports':3,
        'sourceEquivalence':'Exact candidate sources, allowing only contrast tracking default switch',
        'limitations':'LEGO peak flash and mixed-light residual errors remain; no perceptual invisibility guarantee.'}
(FOLDER/'promotion-source-proof.json').write_text(json.dumps(result,indent=2)+'\n')
print('Promotion source and encoded evidence verified')
