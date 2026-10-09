"""Summarize encoded shared-flash experiments without claiming promotion."""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser()
p.add_argument('--revision', required=True)
p.add_argument('--output', type=Path, required=True)
a = p.parse_args()
assert a.revision in ('v2', 'v3') and not a.output.exists()
reports = ROOT/'dist/Benchmarks/general-review-v30'
cases = [
    ('lego', 'smooth', 'lego-registered-anchor-v2-matched-luma-all.json', f'lego-shared-flash-{a.revision}-matched-luma-all.json'),
    ('fox', 'strength-75', None, f'fox-shared-flash-{a.revision}-strength-75-matched-luma-all.json'),
    ('fox', 'smooth', 'fox-registered-anchor-matched-luma-all.json', f'fox-shared-flash-{a.revision}-default-matched-luma-all.json'),
]+[(name, 'smooth', f'{name}-registered-anchor-matched-luma-all.json', f'{name}-shared-flash-{a.revision}-matched-luma-all.json')
   for name in ('clay', 'paper', 'outdoor')]
rows, pending = [], []
for name, profile, baseline, candidate in cases:
    before = reports/baseline if baseline else ROOT/'dist/Benchmarks/review-v33-registered-local-v3-sliders/fox/strength-75/before/matched-luminance.json'
    after = reports/candidate
    if not after.exists():
        pending.append([name, profile])
        continue
    b, c = [json.loads(f.read_text()) for f in (before, after)]
    assert Path(b['source']).resolve() == Path(c['source']).resolve()
    assert len(b['transitions']) == len(c['transitions'])
    pairs = []
    for old, new in zip(b['transitions'], c['transitions']):
        coordinates = lambda t: [(v['x'], v['y'], v['matchedX'], v['matchedY']) for v in t['sourceSelectedMatchedFootprints']]
        assert old['frames'] == new['frames'] and coordinates(old) == coordinates(new)
        if old['supportedFootprints'] >= 12:
            pairs.append((old, new))
    rms = lambda side: math.sqrt(statistics.mean(t[side]['outputMedianAbsoluteLumaStepEV']**2 for t in pairs))
    worst = max(pairs, key=lambda t: t[1]['outputMedianAbsoluteLumaStepEV']-t[0]['outputMedianAbsoluteLumaStepEV'])
    step = lambda pair: {'frames': pair[0]['frames'], 'before': pair[0]['outputMedianAbsoluteLumaStepEV'], 'after': pair[1]['outputMedianAbsoluteLumaStepEV']}
    integrity_path = ROOT/f'dist/Benchmarks/review-v33-shared-flash-{a.revision}-real/{name}/{profile}/media-integrity-independent.json'
    integrity = json.loads(integrity_path.read_text())
    assert integrity['passed']
    rows.append({'case': name, 'profile': profile, 'supportedTransitions': len(pairs),
                 'beforeRMS': rms(0), 'afterRMS': rms(1), 'worstRegression': step(worst),
                 'legoMainFlash': step(next(t for t in pairs if t[0]['frames'] == [187, 188])) if name == 'lego' else None,
                 'mediaIntegrity': integrity,
                 'reportHashes': {str(f.relative_to(ROOT)): hashlib.sha256(f.read_bytes()).hexdigest() for f in (before, after, integrity_path)}})
report = {'status': 'Opt-in experiment; promotion unproven.', 'revision': a.revision,
          'real': rows, 'pendingCases': pending,
          'limitations': 'Overlapping source-selected footprints are not independent and have no clean lighting reference. '
          'Aggregate residual improvements do not prove invisible flashes or perceptual quality. '
          'Sliders and generalization require separate validation.',
          'provenance': json.loads((ROOT/f'.build/review-v33/shared-flash-experiment/runner-{a.revision}/real-build-provenance.json').read_text())}
a.output.write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps([{'case': r['case'], 'profile': r['profile'], 'beforeRMS': r['beforeRMS'], 'afterRMS': r['afterRMS']} for r in rows], indent=2))
