"""Read native pixel scores and publish a baseline report. Python standard library only."""
import argparse
import hashlib
import html
import json
from pathlib import Path

# Initial engineering targets, fixed before evaluating this baseline. These are
# acceptance targets for future development, not claims of perceptual equivalence.
LIMITS = {
    'p95AbsoluteErrorEV': .10,
    'residualFlickerRMSEV': .03,
    'linearRGBRMSE': .025,
    'chromaticityMAE': .01,
    'edgeMAE': .005,
    'clippedFraction': .005,
}
NEGATIVE_LIMITS = {'p95AbsoluteErrorEV': .03, 'residualFlickerRMSEV': .005, 'linearRGBRMSE': .005}


def assess(case):
    issues = []
    if not case['timingAndGeometryPreserved']:
        issues.append('Timing/geometry changed')
    if case['expectedCuts'] != case['detectedCuts']:
        issues.append('Scene-cut detection mismatch')
    for region in ('foreground', 'background'):
        result, floor = case['corrected'][region], case['codecFloor'][region]
        limits = NEGATIVE_LIMITS if case['id'].startswith('no-flicker-') else LIMITS
        for key, tolerance in limits.items():
            # Compare with the measured encode/decode control; do not hide a
            # large floor by subtracting squared errors or aggregating regions.
            if result[key] > floor[key] + tolerance:
                issues.append(f'{region}: {key} exceeds codec floor + {tolerance}')
    return issues


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def report(root, label):
    folder = root / 'results' / label
    scores = json.loads((folder / 'scores.json').read_text())
    manifest = json.loads((root / 'manifest.json').read_text())
    settings = json.loads((folder / 'settings.json').read_text())
    provenance = json.loads((folder / 'provenance.json').read_text())
    provenance['reportHarnessSha256'] = digest(Path(__file__))
    provenance['fixturesSha256'] = {str(p.relative_to(root)): digest(p) for p in sorted((root / 'cases').glob('*/*'))}
    rows, assessment = [], {}
    complete = {c['id'] for c in scores} == {c['id'] for c in manifest['cases']}
    for case in scores:
        failures = assess(case)
        assessment[case['id']] = {'status': 'needs-work' if failures else 'meets-initial-targets', 'issues': failures}
        for region in ('foreground', 'background'):
            a, b = case['source'][region], case['corrected'][region]
            fields = [case['id'], region, f"{a['residualFlickerRMSEV']:.4f} → {b['residualFlickerRMSEV']:.4f}",
                      f"{b['medianErrorEV']:+.4f}", f"{b['p95AbsoluteErrorEV']:.4f}",
                      f"{b['linearRGBRMSE']:.4f}", f"{b['chromaticityMAE']:.4f}", f"{b['edgeMAE']:.4f}"]
            cells = ''.join(f'<td>{html.escape(value)}</td>' for value in fields)
            rows.append(f'<tr>{cells}<td>{html.escape(assessment[case["id"]]["status"])}</td>'
                        f'<td><a href="{case["id"]}/comparison.png">Frames</a> · <a href="{case["id"]}/corrected.mp4">Video</a></td></tr>')
    output = {'manifest': manifest, 'settings': settings, 'thresholdsAboveCodecFloor': LIMITS,
              'negativeControlThresholds': NEGATIVE_LIMITS, 'assessment': assessment,
              'provenance': provenance, 'completeCaseSet': complete, 'scores': scores}
    (folder / 'report.json').write_text(json.dumps(output, indent=2) + '\n')
    page = '''<!doctype html><html lang="en"><meta charset="utf-8"><title>FrankLuma baseline benchmark</title>
<style>body{font:15px system-ui;margin:32px;color:#182028;max-width:1500px}table{border-collapse:collapse;width:100%}td,th{padding:9px;border-bottom:1px solid #ddd;text-align:left}th{background:#eef2f4}p{max-width:1000px;line-height:1.5}a{color:#155fa0}</style>
<h1>FrankLuma baseline benchmark</h1>
<p>Ground-truth synthetic clips, independently generated foreground masks and actual decoded exports.
Foreground and background are scored separately. EV metrics use region-mean linear luminance per frame; RGB, chroma and edge errors also measure spatial differences within each region. Adjacent variation is measured in the error relative to the matching clean frame, so intended motion and fades are not treated as flicker.</p>
<p>Contact sheets: <b>corrupted input · clean target · corrected export</b>. Rows: frames 0, 11, 12, 35, 36, 47, 60, 71.
The clean target is also exported without correction to measure the codec floor. Full values, source fingerprints, settings and acceptance targets are in <a href="report.json">report.json</a>.</p>
<p><b>Needs-work flags are baseline findings.</b> Targets are preliminary engineering tolerances, not perceptual guarantees.
Highlight clipping may destroy information that correction cannot recover. This set does not establish performance on arbitrary real video or equivalence to commercial tools.</p>
<table><thead><tr><th>Case</th><th>Region</th><th>Residual flicker EV RMS</th><th>Median EV error</th><th>P95 abs EV error</th><th>Linear RGB RMSE</th><th>Chroma MAE</th><th>Edge MAE</th><th>Case status</th><th>Review</th></tr></thead><tbody>'''
    (folder / 'report.html').write_text(page + ''.join(rows) + '</tbody></table></html>')
    if not complete:
        print('INCOMPLETE CASE SET: this report cannot be used as a full-suite pass')
    print(folder / 'report.html')
    print(f'{sum(bool(v["issues"]) for v in assessment.values())}/{len(scores)} cases need work against initial targets')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('label')
    args = parser.parse_args()
    report(args.root, args.label)
