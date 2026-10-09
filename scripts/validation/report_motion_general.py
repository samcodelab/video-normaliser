"""Publish measured motion coverage, preserving explicit failures and provenance."""
import hashlib
import html
import json
import math
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'dist/Benchmarks'
OUT = BASE / 'motion-temporal-v26-real'


def read(path):
    return json.loads(path.read_text())


def main():
    log = (ROOT / '.build/motion-v26-native-tests.log').read_text()
    counts = re.findall(r'Executed (\d+) tests, with 0 failures', log)
    assert "Test Suite 'All tests' passed" in log, 'Full native suite must pass'
    assert '** BUILD SUCCEEDED **' in (ROOT / '.build/motion-v26-app-build.log').read_text()
    provenance = read(OUT/'runner/real-build-provenance.json')
    assert all(hashlib.sha256((ROOT/p).read_bytes()).hexdigest() == digest for p,digest in provenance['pipelineSha256'].items())
    assert hashlib.sha256((OUT/'runner/real-audit').read_bytes()).hexdigest() == provenance['binarySha256']
    app = ROOT/'dist/local/FrankLuma.app'
    subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
    binary = app/'Contents/MacOS/FrankLuma'
    assert set(subprocess.check_output(['lipo','-archs',str(binary)],text=True).split()) == {'arm64','x86_64'}
    checks, rows = {}, []
    for suite in ['development', 'holdout']:
        for mode in ['smooth', 'steady']:
            folder = BASE / f'motion-v2-{suite}/results/motion-temporal-v26-{mode}'
            current = read(folder / 'report.json')
            previous = read(folder.parent / f'baseline-v22-{mode}/report.json')
            assert current['completeCaseSet'] and previous['completeCaseSet']
            issues = {k: v['issues'] for k, v in current['assessment'].items() if v['issues']}
            key = f'{suite}-{mode}'
            checks[key] = {'passed': len(current['assessment'])-len(issues), 'total': len(current['assessment']), 'issues': issues, 'previousPassed': sum(not v['issues'] for v in previous['assessment'].values())}
            rows.append(f'<tr><td>{key}</td><td>{checks[key]["passed"]}/{checks[key]["total"]}</td><td>{html.escape(str(issues))}</td><td><a href="../motion-v2-{suite}/results/motion-temporal-v26-{mode}/report.html">Full scores</a></td></tr>')
    current = read(BASE / 'motion-v2-development/results/motion-temporal-v26-smooth/scores.json')
    previous = {c['id']: c for c in read(BASE / 'motion-v2-development/results/baseline-v22-smooth/scores.json')}
    improvements = {}
    for case in current:
        if case['id'] in ['camera-zoom', 'camera-rotation', 'parallax', 'occlusion']:
            old = previous[case['id']]['corrected']['foreground']['residualFlickerRMSEV']
            new = case['corrected']['foreground']['residualFlickerRMSEV']
            improvements[case['id']] = {'previousForegroundResidualEVRMS': old, 'currentForegroundResidualEVRMS': new, 'reductionPercent': 100*(1-new/old)}
    real = {}
    for clip in ['fox', 'lego']:
        values = []
        for path in [BASE/f'regional-validation-final-v22/{clip}/steady', BASE/f'motion-temporal-v26-steady/{clip}']:
            regions = read(path/'regional-brightness-check.json')
            values.append({'regionalEVRMS': math.sqrt(sum(r['outputAdjacentRMSEV']**2*r['supportedFramePairs'] for r in regions)/sum(r['supportedFramePairs'] for r in regions)), 'peakRegionalStepEV': max(r['outputPeakStepEV'] for r in regions)})
        real[clip] = {'previous': values[0], 'current': values[1]}
    result = {'revision': 'motion-temporal-v26', 'testsPassed': max(map(int, counts)), 'appBinarySHA256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'syntheticChecks': checks, 'developmentMotionImprovements': improvements, 'realSteadyDiagnostics': real, 'realInventory': read(OUT/'inventory.json'), 'limitations': ['Synthetic coverage is finite; no arbitrary-video guarantee.', 'Steady intentionally removes exposure ramps and exceeds the strict unchanged-footage tolerance on two camera-motion controls.', 'Real regional diagnostics have no clean reference and include composition changes.']}
    for folder in [OUT/'fox-three-scenes',OUT/'lego-4k',OUT/'paper-animation',OUT/'outdoor-pixilation',BASE/'motion-temporal-v26-steady/fox',BASE/'motion-temporal-v26-steady/lego']:
        integrity = read(folder/'media-integrity.json')
        assert all(integrity[k]['pts_time'] and integrity[k]['duration_time'] and integrity[k]['counts'][0] == integrity[k]['counts'][1] for k in ['video','audio'])
        assert integrity['audio']['payloadsMatch']
    (OUT/'verification.json').write_text(json.dumps(result, indent=2)+'\n')
    movement = ''.join(f'<li>{name}: {values["reductionPercent"]:.1f}% lower foreground residual EV RMS than v22.</li>' for name, values in improvements.items())
    (OUT/'summary.html').write_text(f'''<!doctype html><html lang="en"><meta charset="utf-8"><title>Motion and temporal stability validation</title><style>body{{font:16px system-ui;margin:32px;max-width:1200px}}td,th{{padding:12px;text-align:left;border-bottom:1px solid #ddd}}</style><h1>Motion and temporal stability validation</h1><p>Camera guidance follows translation, rotation and zoom without warping output pixels. Fragmented surface tracks share an exposure anchor only when repeated RGB lighting changes agree. Weak local departures from global correction are attenuated directly to avoid amplifying correspondence noise. Existing Strength, Spatial and Colour controls remain available; no new mode or slider is added.</p><p>{result['testsPassed']} native tests passed. App build succeeded. <a href="verification.json">Verification and fingerprints</a>.</p><h2>Ground-truth encoded benchmarks</h2><p>18 development clips and four separate holdout clips, scored in both modes. Tuning was frozen before holdout evaluation. Negative controls use stricter tolerances. These are engineering checks, not perceptual guarantees.</p><table><tr><th>Suite</th><th>Passes</th><th>Remaining issues</th><th>Evidence</th></tr>{''.join(rows)}</table><ul>{movement}</ul><h2>Real footage</h2><p><a href="report.html">Fox, LEGO, paper animation and outdoor review sheets and actual Smooth exports</a>. All four preserve expected frame counts. <a href="../motion-temporal-v26-steady/fox/corrected.mp4">Fox Steady export</a> · <a href="../motion-temporal-v26-steady/lego/corrected.mp4">LEGO Steady export</a>.</p><p>Real footage has no verified clean reference. Regional brightness measurements remain descriptive; the fox change is small and residual flashes remain. LEGO regional EV RMS rises about 3% and its largest regional step rises about 10%; this remains a measured trade-off, not an across-the-board improvement. This revision chiefly improves robustness under motion rather than removing every flash in the two familiar clips. Steady still introduces small changes in two stable camera-motion controls; Smooth passes them. Use Smooth when preserving gradual lighting changes matters.</p></html>''')
    print(OUT/'summary.html')


if __name__ == '__main__':
    main()
