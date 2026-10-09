"""Compare encoded LEGO exports at identical non-default slider settings."""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'dist/Benchmarks/review-v32-registered-anchor-lego-sliders'
rows = []
for profile in ['strength-75', 'spatial-50', 'balanced']:
    reports = [json.loads((BASE / profile / side / 'matched-luminance.json').read_text())
               for side in ['before', 'after']]
    before, after = reports
    assert before['source'] == after['source']
    supported = []
    assert len(before['transitions']) == len(after['transitions'])
    for a, b in zip(before['transitions'], after['transitions']):
        assert a['frames'] == b['frames']
        assert a['supportedFootprints'] == b['supportedFootprints']
        coords = lambda t: [(p['x'], p['y'], p['matchedX'], p['matchedY'])
                            for p in t['sourceSelectedMatchedFootprints']]
        assert coords(a) == coords(b)
        if a['supportedFootprints'] >= 12:
            supported.append({'frames': a['frames'],
                              'before': a['outputMedianAbsoluteLumaStepEV'],
                              'after': b['outputMedianAbsoluteLumaStepEV']})
    rms = lambda key: math.sqrt(sum(t[key] ** 2 for t in supported) / len(supported))
    rows.append({'profile': profile, 'supportedTransitions': len(supported),
                 'beforeRMS': rms('before'), 'afterRMS': rms('after'),
                 'target': next(t for t in supported if t['frames'] == [168, 169]),
                 'largestOtherIncreaseEV': max(t['after'] - t['before'] for t in supported),
                 'mediaIntegrity': {side: json.loads((BASE / profile / side / 'media-integrity.json').read_text())
                                    for side in ['before', 'after']}})
out = ROOT / 'dist/Benchmarks/general-review-v30/registered-anchor-real-sliders.json'
out.write_text(json.dumps({'profiles': rows,
                          'limitations': 'Overlapping source-selected footprints; no clean lighting ground truth or perceptual guarantee.'}, indent=2) + '\n')
print(json.dumps([{k: v for k, v in row.items() if k != 'mediaIntegrity'} for row in rows], indent=2))
