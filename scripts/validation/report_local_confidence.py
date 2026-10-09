#!/usr/bin/env python3
"""Summarise the reviewed local-confidence revision without relabelling old runs."""
import hashlib
import html
import json
import math
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / 'dist/Benchmarks'
OUT = BASE / 'local-confidence-final-v18'


def read(path):
    return json.loads(path.read_text())


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def weighted_brightness(path, frames):
    rows = read(path)
    starts = [row['startFrame'] for row in rows] + [frames]
    pairs = [starts[i+1]-starts[i]-1 for i in range(len(rows))]
    return math.sqrt(sum(row['adjacentRMSEV']**2*n for row, n in zip(rows, pairs))/sum(pairs))


def main():
    provenance = read(OUT / 'real-build-provenance.json')
    assert all(sha(ROOT/path) == value for path, value in provenance['pipelineSha256'].items()), 'Source changed after export runner build'
    assert sha(OUT / 'runner/real-audit') == provenance['binarySha256']
    test_log = (ROOT / '.build/local-confidence-v18-tests.log').read_text()
    matches = re.findall(r'Executed (\d+) tests, with 0 failures', test_log)
    assert "Test Suite 'All tests' passed" in test_log, 'Final suite has not passed'
    tests = max(map(int, matches))
    app = ROOT / 'dist/local/FrankLuma.app'
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    binary = app / 'Contents/MacOS/FrankLuma'
    arches = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    assert set(arches) == {'arm64', 'x86_64'}
    assert '** BUILD SUCCEEDED **' in (ROOT / '.build/local-confidence-v18-app-build.log').read_text()

    modes = {}
    for mode in ['smooth', 'steady']:
        label = 'local-confidence-final-' + ('steady-' if mode == 'steady' else '') + 'v18'
        report = read(BASE / 'v1/results' / label / 'report.json')
        assert report['completeCaseSet']
        assert report['provenance']['pipelineSha256'] == provenance['pipelineSha256']
        modes[mode] = report
    old = read(BASE / 'v1/results/surface-wide-final-v14/report.json')
    old_scores = {row['id']: row for row in old['scores']}
    score_rows = []
    for row in modes['smooth']['scores']:
        score_rows.append({'case': row['id'], 'v14ForegroundResidualEV': old_scores[row['id']]['corrected']['foreground']['residualFlickerRMSEV'],
                           'v18ForegroundResidualEV': row['corrected']['foreground']['residualFlickerRMSEV'],
                           'assessment': modes['smooth']['assessment'][row['id']]['status']})

    clips = {}
    for clip, previous, frames in [('lego', 'lego-4k', 212), ('fox', 'fox-three-scenes', 600)]:
        data = {'v14SmoothBackgroundRMSEV': weighted_brightness(BASE/'real-wide-final-v14'/previous/'brightness-check.json', frames),
                'v14SteadyBackgroundRMSEV': weighted_brightness(BASE/'lego-fox-smoothness-check'/clip/'steady/brightness-check.json', frames)}
        for mode in ['smooth', 'steady']:
            folder = OUT / clip / mode
            integrity = read(folder / 'packet-integrity.json')
            assert integrity['video']['counts'] == [frames, frames]
            assert integrity['video']['pts_time'] and integrity['video']['duration_time']
            assert integrity['audio']['counts'][0] == integrity['audio']['counts'][1]
            assert integrity['audio']['pts_time'] and integrity['audio']['duration_time'] and integrity['audio']['payloadsMatch']
            regions = read(folder / 'regional-brightness-check.json')
            data[mode] = {'backgroundRMSEV': weighted_brightness(folder/'brightness-check.json', frames),
                          'regionalChecks': len(regions), 'integrity': integrity,
                          'largestRegionalSteps': sorted(regions, key=lambda row: row['outputPeakStepEV'], reverse=True)[:5]}
        clips[clip] = data
    result = {'revision': 'local-confidence-final-v18', 'testsPassed': tests, 'appArchitectures': arches,
              'appBinarySHA256': sha(binary), 'pipelineSha256': provenance['pipelineSha256'],
              'benchmarks': score_rows, 'clips': clips,
              'smoothTargetsPassed': sum(v['status']=='meets-initial-targets' for v in modes['smooth']['assessment'].values()),
              'steadyTargetsPassed': sum(v['status']=='meets-initial-targets' for v in modes['steady']['assessment'].values())}
    (OUT / 'verification.json').write_text(json.dumps(result, indent=2)+'\n')
    rows = ''.join(f"<tr><td>{html.escape(r['case'])}</td><td>{r['v14ForegroundResidualEV']:.4f}</td><td>{r['v18ForegroundResidualEV']:.4f}</td><td>{r['assessment']}</td></tr>" for r in score_rows)
    real = ''.join(f"<tr><td>{clip.upper()}</td><td>{d['v14SmoothBackgroundRMSEV']:.5f}</td><td>{d['v14SteadyBackgroundRMSEV']:.5f}</td><td>{d['smooth']['backgroundRMSEV']:.5f}</td><td>{d['steady']['backgroundRMSEV']:.5f}</td></tr>" for clip, d in clips.items())
    (OUT / 'report.html').write_text(f'''<!doctype html><html lang="en"><meta charset="utf-8"><title>FrankLuma local confidence revision</title>
<style>body{{font:16px system-ui;line-height:1.5;margin:32px;max-width:1250px}}td,th{{padding:9px;border-bottom:1px solid #ccc;text-align:left}}img{{width:100%;height:auto}}a{{color:#155fa0}}</style>
<h1>Local confidence and colour control — 6 October 2026</h1>
<p>Reviewed revision v18. Camera matches now require coherent photometric evidence. Newly revealed surfaces build support gradually. Weak or conflicting local gains fade towards global correction, including the distant-material fallback. Confidence is independent of the Strength slider.</p>
<p>Colour correction amount interpolates local RGB gains while preserving estimated guide-pixel linear luminance. At 0%, local gains are achromatic. Strength, Spatial correction and manual frame EV remain available; existing projects default to 100% colour correction.</p>
<p><b>{tests} native tests passed.</b> Universal arm64/x86_64 app built and signature verified. Both clips were exported in both modes; video frame counts, exact sample timestamps/durations and audio packet integrity were checked. <a href="verification.json">Verification and source fingerprints</a>.</p>
<h2>Controlled clean-reference benchmarks</h2>
<p>Smooth meets {result['smoothTargetsPassed']}/10 initial engineering targets. Steady meets {result['steadyTargetsPassed']}/10; its intentional-ramp failure is expected because it flattens gradual lighting. These are development thresholds, not a guarantee of invisible flicker.</p>
<table><tr><th>Case</th><th>v14 foreground residual EV RMS</th><th>v18 foreground residual EV RMS</th><th>v18 Smooth assessment</th></tr>{rows}</table>
<p>The confidence changes trade some local-moving foreground performance for more conservative local gains. That case remains within the declared target and much better than the frozen global-era baseline. The short-shot linear-trend experiment (v16) worsened results and was rejected.</p>
<p><a href="../v1/results/local-confidence-final-v18/report.html">Full Smooth scores</a> · <a href="../v1/results/local-confidence-final-steady-v18/report.html">Full Steady scores</a> · <a href="../final-summary.html">Earlier v14 implementation report</a></p>
<h2>Actual encoded LEGO and fox exports</h2>
<p>Source-selected stable-background adjacent EV RMS, weighted across each clip's shots. This measurement has no clean target and excludes unsupported content. Steady is the appropriate existing mode for constant exposure; Smooth deliberately retains gradual changes.</p>
<table><tr><th>Clip</th><th>v14 Smooth</th><th>v14 Steady</th><th>v18 Smooth</th><th>v18 Steady</th></tr>{real}</table>
<p>Fox's Steady background measurement improves slightly. LEGO's scene-median RMS is slightly higher than the previous Steady export, while the reviewed camera-pan gain artifacts are reduced. The revision does not improve every metric; local consistency and source appearance must be assessed together.</p>
<p>The audit now also checks twelve separate regions, exposing local changes that a scene median can hide. Regional changes can include composition shifts during camera motion or occlusion; they are not independently verified lighting errors. Unsupported regions are omitted. <a href="lego/steady/regional-brightness-check.json">LEGO regional checks</a> · <a href="fox/steady/regional-brightness-check.json">Fox regional checks</a>.</p>
<p><a href="lego/steady/corrected.mp4">LEGO Steady export</a> · <a href="fox/steady/corrected.mp4">Fox Steady export</a> · <a href="lego/smooth/corrected.mp4">LEGO Smooth export</a> · <a href="fox/smooth/corrected.mp4">Fox Smooth export</a>.</p>
<h2>LEGO camera pan: encoded frames 85–87, zero-based</h2>
<p>The conspicuous bright/yellowish gain mottling on the blue backdrop is reduced in this reviewed sequence. Underlying source texture remains visible. Selected-frame inspection does not establish that every frame is artifact-free.</p>
<p>Original</p><img src="lego-original-85-87.png" alt="Three original frames during the camera pan">
<p>Previous Steady correction (v14)</p><img src="../lego-fox-smoothness-check/lego-cut-steady-triplet.png" alt="Previous corrected camera-pan frames">
<p>Reviewed Steady correction (v18)</p><img src="lego-steady-85-87.png" alt="New corrected camera-pan frames">
<h2>Fox flash: encoded frames 348–350, zero-based</h2><p>Original</p><img src="fox-original-348-350.png" alt="Original fox flash frames"><p>Reviewed Steady correction</p><img src="fox-steady-348-350.png" alt="Corrected fox flash frames">
</html>''')
    print(json.dumps({key: result[key] for key in ['revision', 'testsPassed', 'smoothTargetsPassed', 'steadyTargetsPassed']}))


if __name__ == '__main__':
    main()
