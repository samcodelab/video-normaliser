"""Report exact paired real exports at non-default controls, including pending work."""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'dist/Benchmarks/review-v33-registered-local-v3-sliders'
rows, pending = [], []
for name in ['lego', 'fox']:
    for profile in ['strength-75', 'spatial-50', 'balanced']:
        before = (ROOT / f'dist/Benchmarks/review-v32-registered-anchor-lego-sliders/{profile}/after'
                  if name == 'lego' else BASE / name / profile / 'before')
        after = BASE / name / profile / 'after'
        if any(not (folder / 'matched-luminance.json').exists() for folder in [before, after]):
            pending.append(f'{name}/{profile}')
            continue
        a, b = [json.loads((folder / 'matched-luminance.json').read_text()) for folder in [before, after]]
        assert a['source'] == b['source']
        assert len(a['transitions']) == len(b['transitions'])
        paired = []
        for x, y in zip(a['transitions'], b['transitions']):
            assert x['frames'] == y['frames'] and x['supportedFootprints'] == y['supportedFootprints']
            coords = lambda t: [(p['x'], p['y'], p['matchedX'], p['matchedY']) for p in t['sourceSelectedMatchedFootprints']]
            assert coords(x) == coords(y)
            if x['supportedFootprints'] >= 12:
                paired.append({'frames': x['frames'], 'before': x['outputMedianAbsoluteLumaStepEV'],
                               'after': y['outputMedianAbsoluteLumaStepEV']})
        rms = lambda key: math.sqrt(sum(t[key]**2 for t in paired)/len(paired))
        integrity = [json.loads((folder / 'media-integrity.json').read_text()) for folder in [before, after]]
        assert all(x['passed'] for x in integrity)
        rows.append({'case': name, 'profile': profile, 'supportedTransitions': len(paired),
                     'beforeRMS': rms('before'), 'afterRMS': rms('after'),
                     'worstIncrease': max(paired, key=lambda t: t['after']-t['before']),
                     'beforeFolder': str(before), 'afterFolder': str(after), 'mediaIntegrity': integrity})
report = {'completedPairs': len(rows), 'expectedPairs': 6, 'pendingPairs': pending, 'comparisons': rows,
          'limitations': 'Overlapping source-selected footprints; no clean lighting target or guarantee of invisible flashes.'}
out = ROOT / 'dist/Benchmarks/general-review-v30/registered-local-real-sliders.json'
out.write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({'completedPairs': len(rows), 'pendingPairs': pending}, indent=2))
