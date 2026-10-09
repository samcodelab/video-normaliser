"""Verify and report the conservative camera-correspondence correction."""
import hashlib
import html
import json
import math
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT/'dist/Benchmarks'
OUT = BASE/'lego-final-v28'


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regional(path):
    values = read(path/'regional-brightness-check.json')
    return {'rmsEV': math.sqrt(sum(v['outputAdjacentRMSEV']**2*v['supportedFramePairs'] for v in values)/sum(v['supportedFramePairs'] for v in values)), 'peakEV': max(v['outputPeakStepEV'] for v in values)}


def main():
    provenance = read(OUT/'runner/real-build-provenance.json')
    assert all(digest(ROOT/p)==value for p,value in provenance['pipelineSha256'].items())
    assert digest(OUT/'runner/real-audit')==provenance['binarySha256']
    log = (ROOT/'.build/lego-final-v28-native-tests.log').read_text()
    assert "Test Suite 'All tests' passed" in log
    tests = max(map(int,re.findall(r'Executed (\d+) tests, with 0 failures',log)))
    app = ROOT/'dist/local/FrankLuma.app'
    subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
    binary = app/'Contents/MacOS/FrankLuma'
    assert set(subprocess.check_output(['lipo','-archs',str(binary)],text=True).split())=={'arm64','x86_64'}
    assert '** BUILD SUCCEEDED **' in (ROOT/'.build/lego-final-v28-app-build.log').read_text()
    suites, rows = {}, []
    for suite in ['development','holdout']:
        for mode in ['smooth','steady']:
            folder = BASE/f'motion-v2-{suite}/results/lego-final-v28-{mode}'
            report = read(folder/'report.json')
            assert report['completeCaseSet']
            issues = {k:v['issues'] for k,v in report['assessment'].items() if v['issues']}
            key = f'{suite}-{mode}'
            suites[key] = {'passed':len(report['assessment'])-len(issues),'total':len(report['assessment']),'issues':issues}
            rows.append(f'<tr><td>{key}</td><td>{suites[key]["passed"]}/{suites[key]["total"]}</td><td>{html.escape(str(issues))}</td><td><a href="../motion-v2-{suite}/results/lego-final-v28-{mode}/report.html">Scores</a></td></tr>')
    clips = {}
    for clip in ['lego','fox']:
        previous = regional(BASE/f'motion-temporal-v26-steady/{clip}')
        current = regional(OUT/clip)
        early = regional(BASE/f'regional-validation-final-v22/{clip}/steady')
        clips[clip] = {'v26':previous,'v22':early,'current':current,'rmsReductionVsV26Percent':100*(1-current['rmsEV']/previous['rmsEV'])}
        assert 'EXPORT VERIFIED' in (OUT/clip/'audit.log').read_text()
        for folder in [OUT/clip,BASE/'lego-final-v28-smooth'/('lego-4k' if clip=='lego' else 'fox-three-scenes')]:
            integrity = read(folder/'media-integrity.json')
            assert all(integrity[k]['pts_time'] and integrity[k]['duration_time'] and integrity[k]['counts'][0]==integrity[k]['counts'][1] for k in ['video','audio'])
            assert integrity['audio']['payloadsMatch']
    half = regional(BASE/'lego-isolation-v27/spatial-half')
    result = {'revision':'lego-final-v28','testsPassed':tests,'appBinarySha256':digest(binary),'provenance':provenance,'checks':suites,'realSteadyDiagnostics':clips,'spatialHalfDiagnosticBeforeFix':half,'limitations':['Fixed source regions include composition changes; real clips lack clean targets.','LEGO peak regional step remains above v22; flashes are not all resolved.','The separate holdout clips were already evaluated in v26 and are regression checks here, not a newly unseen test set.','Steady still exceeds strict stable zoom and rotation control tolerances and intentionally flattens the exposure ramp.']}
    (OUT/'verification.json').write_text(json.dumps(result,indent=2)+'\n')
    lego = clips['lego']
    (OUT/'report.html').write_text(f'''<!doctype html><html lang="en"><meta charset="utf-8"><title>LEGO camera matching fix</title><style>body{{font:16px system-ui;margin:32px;max-width:1200px}}td,th{{padding:12px;border-bottom:1px solid #ddd;text-align:left}}</style><h1>LEGO camera matching fix</h1><p>The previous camera guidance could override a valid local correspondence on repeated textures, making a reflectance mismatch look like lighting. Camera guidance now fills failed matches and replaces a valid one only when its texture error is weak (above 0.06) and the guided error is at least 40% lower. A regression test uses repeated texture at different brightness under an incorrect camera prediction to verify that the original surface retains its exposure.</p><p>Existing Strength, Spatial and Colour sliders remain available. No new mode or slider is added. {tests} native tests pass; the universal app builds and its signature verifies. <a href="verification.json">Full measurements and source fingerprints</a>.</p><h2>Actual LEGO exports</h2><p>Steady regional EV RMS: {lego['v26']['rmsEV']:.5f} → {lego['current']['rmsEV']:.5f}, a {lego['rmsReductionVsV26Percent']:.1f}% reduction versus v26; v22 was {lego['v22']['rmsEV']:.5f}. Largest regional step: {lego['v26']['peakEV']:.4f} → {lego['current']['peakEV']:.4f} EV; v22 was {lego['v22']['peakEV']:.4f}. The peak is still above v22 and this does not establish that every flash is removed.</p><p>At 50% Spatial on the pre-fix algorithm, regional RMS was {half['rmsEV']:.5f} EV: worse overall despite a smaller peak. Reducing Spatial may help a particular artifact, but is not a general LEGO fix. Strength reduces all automatic correction; Colour reduces colour-specific correction. These remain user controls, not substitutes for reliable correspondence.</p><p><a href="lego/corrected.mp4">LEGO Steady export</a> · <a href="../lego-final-v28-smooth/lego-4k/corrected.mp4">LEGO Smooth export</a> · <a href="lego/comparison.png">LEGO source/corrected review</a> · <a href="fox/corrected.mp4">Fox Steady export</a>. Fox regional metrics remain effectively unchanged. Timing, frame counts and audio payloads match the sources.</p><p><a href="lego/encoded-82.png">LEGO encoded frames 82–84</a> · <a href="lego/encoded-85.png">LEGO encoded frames 85–87</a> · <a href="lego/encoded-166.png">LEGO encoded frames 166–168</a> · <a href="fox/encoded-348.png">Fox encoded frames 348–350</a>.</p><h2>Regression coverage</h2><p>18 development clips plus four previously evaluated separate clips, both correction modes. No threshold was relaxed. The separate clips are regression checks, not a newly unseen holdout. Steady intentionally flattens the exposure ramp and still adds small brightness changes to two stable camera-motion controls. Smooth preserves those controls.</p><table><tr><th>Suite</th><th>Passes</th><th>Issues</th><th>Evidence</th></tr>{''.join(rows)}</table><p>Real measurements use supported frame pairs from source-selected regions; they include camera composition changes and have no verified clean reference. Encoded review triplets are saved next to exports.</p></html>''')
    print(OUT/'report.html')


if __name__ == '__main__':
    main()
