"""Compare immutable trajectory-support exports with the preceding candidate."""
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BENCH = ROOT/'dist/Benchmarks'


def regional(folder):
    values = json.loads((folder/'regional-brightness-check.json').read_text())
    count = sum(x['supportedFramePairs'] for x in values)
    if not count:
        return {'supportedPairs': 0, 'rmsEV': None, 'peakEV': None}
    return {'supportedPairs': count,
            'rmsEV': math.sqrt(sum(x['outputAdjacentRMSEV']**2*x['supportedFramePairs'] for x in values)/count),
            'peakEV': max(x['outputPeakStepEV'] for x in values)}


def collect():
    baseline = BENCH/'motion-v2-development/results/photometric-confidence-v1-smooth/scores.json'
    candidate = BENCH/'motion-v2-development/results/trajectory-support-v1-smooth/scores.json'
    before = {x['id']: x for x in json.loads(baseline.read_text())}
    after = json.loads(candidate.read_text())
    assert {x['id'] for x in after} == set(before)
    synthetic = []
    for item in after:
        assert item['timingAndGeometryPreserved'] and item['detectedCuts'] == item['expectedCuts']
        synthetic.append({'case': item['id'], 'regions': {
            region: {'before': before[item['id']]['corrected'][region],
                     'after': item['corrected'][region],
                     'rmsChangeEV': item['corrected'][region]['residualFlickerRMSEV']-before[item['id']]['corrected'][region]['residualFlickerRMSEV']}
            for region in ['foreground','background']}})
    real = []
    for name, case in [('lego','lego-4k'),('fox','fox-three-scenes')]:
        real.append({'case': case,
                     'before': regional(BENCH/f'review-v31-photometric-confidence-real/{case}/smooth'),
                     'after': regional(BENCH/f'review-v31-trajectory-support-real/{name}/smooth')})
    provenance = json.loads((ROOT/'.build/review-v31/trajectory-support-experiment/runner/build-provenance.json').read_text())
    additional = []
    for suite in ['motion-v2-holdout','adversarial-v30']:
        candidate_scores = BENCH/suite/'results/trajectory-support-v1-smooth/scores.json'
        if not candidate_scores.exists():
            continue
        previous = {x['id']: x for x in json.loads((BENCH/suite/'results/photometric-confidence-v1-smooth/scores.json').read_text())}
        results = json.loads(candidate_scores.read_text())
        for item in results:
            assert item['timingAndGeometryPreserved'] and item['detectedCuts'] == item['expectedCuts']
            additional.append({'suite': suite, 'case': item['id'], 'rmsChangeEV': {
                region: item['corrected'][region]['residualFlickerRMSEV']-previous[item['id']]['corrected'][region]['residualFlickerRMSEV']
                for region in ['foreground','background']}})
    return {'status': 'Rejected: rolling-band foreground RMS rises by 0.00913 EV; LEGO peak barely changes and Fox peak worsens. Source restored.',
            'options': {'FRANKLUMA_CONTRAST_TRACKING':'1','FRANKLUMA_TRAJECTORY_SUPPORT':'1'},
            'runnerProvenance': provenance,'synthetic': synthetic,'real': real,'additionalSynthetic': additional,
            'limitations': 'Real regional variation has no verified clean reference. Reduced variation alone does not establish perceptual accuracy.'}


if __name__ == '__main__':
    report = collect()
    output = BENCH/'general-review-v30/trajectory-support-review.json'
    output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'real':report['real'],'largestForegroundRMSIncreaseEV':max(x['regions']['foreground']['rmsChangeEV'] for x in report['synthetic'])},indent=2))
