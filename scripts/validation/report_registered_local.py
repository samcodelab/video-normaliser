"""Keep paired local-refinement evidence and incomplete coverage explicit."""
import json
import math
import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'dist/Benchmarks/general-review-v30'
parser = argparse.ArgumentParser()
parser.add_argument('--revision', choices=['v2', 'v3'], default='v2')
revision = parser.parse_args().revision
rows, pending = [], []
for suite in ['motion-v2-development', 'motion-v2-holdout', 'adversarial-v30']:
    folder = ROOT / 'dist/Benchmarks' / suite
    expected = {x['id'] for x in json.loads((folder / 'manifest.json').read_text())['cases']}
    results = folder / 'results'
    before = {x['id']: x for x in json.loads((results / 'registered-anchor-v1-smooth/scores.json').read_text())}
    path = results / f'registered-local-{revision}-smooth/scores.json'
    if not path.exists():
        # The full slider sweep's default profile is the same settings and
        # immutable runner; do not launch duplicate default-only jobs.
        path = results / f'slider-range-v33-registered-local-{revision}-smooth-default/scores.json'
    after = json.loads(path.read_text()) if path.exists() else []
    pending += [f'{suite}/{name}' for name in sorted(expected - {x['id'] for x in after})]
    for item in after:
        assert item['timingAndGeometryPreserved'] and item['detectedCuts'] == item['expectedCuts']
        rows.append({'suite': suite, 'case': item['id'], 'regions': {
            region: {'before': before[item['id']]['corrected'][region], 'after': item['corrected'][region]}
            for region in ['foreground', 'background']}})
real, missing = [], []
for name, baseline in [('lego', 'lego-registered-anchor-v2'), ('fox', 'fox-registered-anchor'),
                       ('clay-armature', 'clay'), ('paper-animation', 'paper'), ('outdoor-pixilation', 'outdoor')]:
    candidate = OUT / f'{name}-registered-local-{revision}-matched-luma-all.json'
    if not candidate.exists():
        missing.append(name)
        continue
    a = json.loads((OUT / f'{baseline}-matched-luma-all.json').read_text())['transitions']
    b = json.loads(candidate.read_text())['transitions']
    assert len(a) == len(b)
    pairs = []
    for x, y in zip(a, b):
        assert x['frames'] == y['frames'] and x['supportedFootprints'] == y['supportedFootprints']
        coordinates = lambda t: [(p['x'], p['y'], p['matchedX'], p['matchedY']) for p in t['sourceSelectedMatchedFootprints']]
        assert coordinates(x) == coordinates(y)
        if x['supportedFootprints'] >= 12:
            pairs.append((x, y))
    rms = lambda side: math.sqrt(sum(p[side]['outputMedianAbsoluteLumaStepEV']**2 for p in pairs)/len(pairs))
    worst = max(pairs, key=lambda p: p[1]['outputMedianAbsoluteLumaStepEV']-p[0]['outputMedianAbsoluteLumaStepEV'])
    integrity = json.loads((ROOT / f'dist/Benchmarks/review-v33-registered-local-{revision}-real/{name}/smooth/media-integrity.json').read_text())
    assert integrity['passed']
    real.append({'case': name, 'supportedTransitions': len(pairs), 'beforeRMS': rms(0), 'afterRMS': rms(1),
                 'worstIncrease': {'frames': worst[0]['frames'], 'before': worst[0]['outputMedianAbsoluteLumaStepEV'],
                                   'after': worst[1]['outputMedianAbsoluteLumaStepEV']}, 'mediaIntegrity': integrity})
test_path = ROOT / f'.build/review-v33/registered-local-experiment/full-tests-{revision}.log'
passed = re.search(r"Test Suite 'All tests' passed[^\n]*\n\s*Executed (\d+) tests, with 0 failures", test_path.read_text()) if test_path.exists() else None
report = {'status': 'Experimental opt-in; not in app33. Boundary regressions remain under review.',
          'revision': revision, 'fullNativeTestsPassed': int(passed.group(1)) if passed else None,
          'syntheticCompleted': len(rows), 'syntheticExpected': 30, 'pendingCases': pending, 'synthetic': rows,
          'real': real, 'pendingRealCases': missing,
          'provenance': json.loads((ROOT / f'.build/review-v33/registered-local-experiment/runner-{revision}/build-provenance.json').read_text()),
          'limitations': 'Overlapping source-selected footprints; no clean real lighting target or perceptual invisibility guarantee. Full slider sweep still required.'}
(OUT / f'registered-local-{revision}-review.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({'syntheticCompleted': len(rows), 'pendingCases': pending, 'pendingRealCases': missing}, indent=2))
