"""Require complete candidate evidence before accepting a default switch."""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FOLDER = ROOT / '.build/review-v32/registered-anchor-experiment'
OUT = ROOT / 'dist/Benchmarks/general-review-v30'
sweep = json.loads((OUT / 'registered-anchor-slider-sweep.json').read_text())
assert sweep['complete'] and sweep['completedEncodedCases'] == 450 and not sweep['pendingProfiles']
provenance = json.loads((FOLDER / 'runner-v2/build-provenance.json').read_text())
assert hashlib.sha256((FOLDER / 'runner-v2/audit').read_bytes()).hexdigest() == provenance['binarySha256']
verified = {}
for filename, expected in provenance['pipelineSha256'].items():
    data = (ROOT / filename).read_bytes()
    if filename.endswith('/Scenes.swift'):
        before = b'ProcessInfo.processInfo.environment["FRANKLUMA_REGISTERED_ANCHOR"] == "1"'
        after = b'ProcessInfo.processInfo.environment["FRANKLUMA_REGISTERED_ANCHOR"] != "0"'
        assert data.count(before) + data.count(after) == 1
        data = data.replace(after, before)
    assert hashlib.sha256(data).hexdigest() == expected, filename
    verified[filename] = hashlib.sha256((ROOT / filename).read_bytes()).hexdigest()
test_log = (FOLDER / 'full-tests-v2.log').read_text()
passed = re.search(r"Test Suite 'All tests' passed[^\n]*\n\s*Executed (\d+) tests, with 0 failures", test_log)
assert passed and int(passed.group(1)) >= 146, 'Complete native suite has not passed'
integration_log = (FOLDER / 'anchor-integration-test.log').read_text()
assert "testRegisteredCameraAnchorReducesManufacturedExposureSpikeWithoutChangingSurfaceMaps]' passed" in integration_log
assert 'Executed 1 test, with 0 failures' in integration_log
media = []
for name in ['lego', 'fox', 'clay-armature', 'paper-animation', 'outdoor-pixilation']:
    media.append(ROOT / f'dist/Benchmarks/review-v32-registered-anchor-real/{name}/smooth/media-integrity.json')
for profile in ['strength-75', 'spatial-50', 'balanced']:
    for side in ['before', 'after']:
        media.append(ROOT / f'dist/Benchmarks/review-v32-registered-anchor-lego-sliders/{profile}/{side}/media-integrity.json')
media.append(ROOT / 'dist/Benchmarks/review-v32-registered-anchor-v2-lego/smooth/media-integrity.json')
assert all(json.loads(path.read_text())['passed'] for path in media)
v1 = json.loads((OUT / 'lego-registered-anchor-matched-luma-all.json').read_text())['transitions']
v2 = json.loads((OUT / 'lego-registered-anchor-v2-matched-luma-all.json').read_text())['transitions']
assert len(v1) == len(v2)
for a, b in zip(v1, v2):
    for key in ['frames', 'supportedFootprints', 'outputMedianAbsoluteLumaStepEV', 'sourceMedianAbsoluteLumaStepEV']:
        assert a[key] == b[key]
result = {'candidateBinarySha256': provenance['binarySha256'], 'currentSourceSha256': verified,
          'nativeTestsPassed': int(passed.group(1)), 'additionalIntegrationTestsPassed': 1,
          'sliderCases': 450, 'mediaChecksPassed': len(media),
          'sourceEquivalence': 'Exact guarded candidate, permitting only registered-anchor default switch',
          'limitations': 'Small real transition regressions remain; no clean real lighting target or perceptual invisibility guarantee.'}
(FOLDER / 'promotion-source-proof.json').write_text(json.dumps(result, indent=2) + '\n')
print('Registered-camera candidate promotion evidence verified')
