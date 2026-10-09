"""Compare channel-history correspondence prototypes at the settings that exposed real regressions."""
import argparse
import json
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'dist/Benchmarks/general-review-v30'
parser = argparse.ArgumentParser()
parser.add_argument('--revision', required=True)
revision = parser.parse_args().revision
assert re.fullmatch(r'v\d+', revision)
rows, pending = [], []
for name, profile, baseline in [
    ('lego', 'smooth', OUT / 'lego-registered-anchor-v2-matched-luma-all.json'),
    ('fox', 'strength-75', ROOT / 'dist/Benchmarks/review-v33-registered-local-v3-sliders/fox/strength-75/before/matched-luminance.json')]:
    path = OUT / f'{name}-channel-history-{revision}-{profile}-matched-luma-all.json'
    if not path.exists():
        pending.append(name)
        continue
    before, after = [json.loads(p.read_text()) for p in [baseline, path]]
    assert before['source'] == after['source']
    assert len(before['transitions']) == len(after['transitions'])
    pairs = []
    for a, b in zip(before['transitions'], after['transitions']):
        assert a['frames'] == b['frames'] and a['supportedFootprints'] == b['supportedFootprints']
        coords = lambda t: [(p['x'], p['y'], p['matchedX'], p['matchedY']) for p in t['sourceSelectedMatchedFootprints']]
        assert coords(a) == coords(b)
        if a['supportedFootprints'] >= 12:
            pairs.append((a, b))
    rms = lambda side: math.sqrt(sum(x[side]['outputMedianAbsoluteLumaStepEV']**2 for x in pairs)/len(pairs))
    worst = max(pairs, key=lambda p: p[1]['outputMedianAbsoluteLumaStepEV']-p[0]['outputMedianAbsoluteLumaStepEV'])
    step = lambda p: {'frames': p[0]['frames'], 'source': p[0]['sourceMedianAbsoluteLumaStepEV'],
                      'before': p[0]['outputMedianAbsoluteLumaStepEV'], 'after': p[1]['outputMedianAbsoluteLumaStepEV']}
    integrity = json.loads((ROOT / f'dist/Benchmarks/review-v33-channel-history-{revision}-real/{name}/{profile}/media-integrity.json').read_text())
    assert integrity['passed']
    row = {'case': name, 'profile': profile, 'supportedTransitions': len(pairs),
           'beforeRMS': rms(0), 'afterRMS': rms(1), 'worstIncrease': step(worst), 'mediaIntegrity': integrity}
    if name == 'fox':
        row['trackedRegressions'] = [step(next(p for p in pairs if p[0]['frames'] == frames))
                                    for frames in [[162, 163], [163, 164], [302, 303]]]
    rows.append(row)
log = ROOT / f'.build/review-v33/channel-history-experiment/full-tests-{revision}.log'
if revision == 'v1': log = log.with_name('full-tests-v1-explicit-disable.log')
passed = re.search(r"Test Suite 'All tests' passed[^\n]*\n\s*Executed (\d+) tests, with 0 failures", log.read_text()) if log.exists() else None
report = {'status': 'Opt-in prototype; preliminary real comparisons only.', 'revision': revision,
          'environment': {'FRANKLUMA_CHANNEL_HISTORY': '1', 'FRANKLUMA_REGISTERED_ANCHOR': 'default enabled'},
          'real': rows, 'pendingCases': pending, 'nativeTestsPassed': int(passed.group(1)) if passed else None,
          'provenance': json.loads((ROOT / f'.build/review-v33/channel-history-experiment/runner-{revision}/build-provenance.json').read_text()),
          'limitations': 'Overlapping source-selected footprints; no clean real lighting target; broad validation required.'}
suite = ROOT / 'dist/Benchmarks/motion-v2-development/results'
baselineScores = suite / 'registered-anchor-v1-smooth/scores.json'
candidateScores = suite / f'channel-history-{revision}-smooth/scores.json'
if candidateScores.exists():
    beforeScores = {r['id']: r for r in json.loads(baselineScores.read_text())}
    candidate = json.loads(candidateScores.read_text())
    differences = []
    for row in candidate:
        original = beforeScores[row['id']]
        assert row['frameCount'] == original['frameCount']
        assert row['detectedCuts'] == original['detectedCuts'] == row['expectedCuts']
        for region in ['foreground', 'background']:
            for metric, value in row['corrected'][region].items():
                delta = value-original['corrected'][region][metric]
                if delta:
                    differences.append({'case': row['id'], 'region': region, 'metric': metric, 'delta': delta})
    report['synthetic'] = {'completedCases': len(candidate), 'expectedCases': len(beforeScores),
                           'cutsAndFrameCountsMatch': True, 'changedMetrics': differences}
(OUT / f'channel-history-{revision}-probe-review.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps([{k: v for k, v in row.items() if k != 'mediaIntegrity'} for row in rows], indent=2))
