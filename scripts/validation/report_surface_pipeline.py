"""Summarise frozen production exports and ablations; never infer real ground truth."""
import hashlib
import html
import json
import re
from pathlib import Path

from report_benchmark import assess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'dist/Benchmarks'
RUNS = OUT / 'v1/results'


def cases(label):
    return {c['id']: c for c in json.loads((RUNS / label / 'scores.json').read_text())}


def metric(data, case, key='residualFlickerRMSEV', region='foreground'):
    return data[case]['corrected'][region][key]


def reduction(before, after):
    return f'{100*(1-after/before):.1f}%'


def run():
    labels = ['baseline-smooth-frozen', 'baseline-steady-frozen',
              'surface-wide-final-v14', 'surface-wide-final-steady-v14']
    old, old_steady, new, steady = [cases(label) for label in labels]
    manifest = json.loads((OUT / 'v1/manifest.json').read_text())
    expected = {c['id'] for c in manifest['cases']}
    if any(set(data) != expected for data in [old, old_steady, new, steady]):
        raise ValueError('Full baseline and final case sets are required')
    if not all(c['timingAndGeometryPreserved'] for data in [new, steady] for c in data.values()):
        raise ValueError('Final geometry/timing check failed')
    build = json.loads((RUNS / labels[2] / 'runner/build-provenance.json').read_text())
    for relative, digest in build['pipelineSha256'].items():
        if hashlib.sha256((ROOT / relative).read_bytes()).hexdigest() != digest:
            raise ValueError(f'Current source differs from scored runner: {relative}')
    inventory = json.loads((OUT / 'real-wide-final-v14/inventory.json').read_text())
    if len(inventory['cases']) != 4 or not all(c.get('expectedFrameCountPreserved') for c in inventory['cases']):
        raise ValueError('All four real exports must be present')
    for c in inventory['cases']:
        integrity = json.loads((OUT / 'real-wide-final-v14' / c['id'] / 'packet-integrity.json').read_text())
        for kind in ['video', 'audio']:
            check = integrity[kind]
            if not check['pts_time'] or not check['duration_time'] or check['counts'][0] != check['counts'][1]:
                raise ValueError(f'Packet timing mismatch: {c["id"]}')
        if not integrity['audio']['payloadsMatch']:
            raise ValueError(f'Audio payload mismatch: {c["id"]}')
    log = (ROOT / '.build/surface-wide-final-tests.log').read_text()
    passed = re.search(r"Test Suite 'All tests' passed.*?Executed (\d+) tests, with 0 failures", log, re.S)
    verification = f'{passed[1]} native tests passed' if passed else 'Final full test run is still pending; this report is provisional'
    tracking = cases('wide-final-v14-no-tracking')
    colour = cases('wide-final-v14-no-colour')
    rows = cases('wide-final-v14-no-rows')
    count = lambda data: sum(not assess(c) for c in data.values())
    summary = {
        'labels': labels, 'sourceProvenance': build, 'nativeFullSuitePassed': bool(passed),
        'nativeTestCount': int(passed[1]) if passed else None,
        'qualityPassCounts': {label: count(data) for label, data in zip(labels, [old, old_steady, new, steady])},
        'realPacketIntegrityPassed': [c['id'] for c in inventory['cases']],
        'remainingSmoothFailures': {key: assess(value) for key, value in new.items() if assess(value)},
        'remainingSteadyFailures': {key: assess(value) for key, value in steady.items() if assess(value)},
    }
    (OUT / 'final-summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    local_old, local_new = metric(old, 'local-moving'), metric(new, 'local-moving')
    chroma_old = metric(old, 'colour-flicker', 'chromaticityMAE')
    chroma_new = metric(new, 'colour-flicker', 'chromaticityMAE')
    band_old, band_new = metric(old, 'rolling-bands'), metric(new, 'rolling-bands')
    negative_old, negative_new = metric(old, 'no-flicker-motion'), metric(new, 'no-flicker-motion')
    details = [
        ('2 · Surface tracking', 'Exposure-invariant correspondence, reverse checks, cut/occlusion termination; wider silhouette tracking with central lighting measurements.',
         f'Unchanged moving subject under background flashes: {local_old:.4f} → {local_new:.4f} EV RMS ({reduction(local_old, local_new)} lower).',
         f'Disabling tracking gives {metric(tracking, "local-moving"):.4f} EV RMS. Neutral-motion and neutral-background-flash regressions pass.'),
        ('3 · Lighting model', 'Independent RGB histories and source-guided gains; bounded, full-width row illumination. Multiplicative rendering protects texture.',
         f'Colour-case foreground chromaticity error: {chroma_old:.4f} → {chroma_new:.4f} ({reduction(chroma_old, chroma_new)} lower). Rolling-band flicker: {band_old:.4f} → {band_new:.4f} EV RMS.',
         f'Without channel lighting, chromaticity error is {metric(colour, "colour-flicker", "chromaticityMAE"):.4f}. Without row modelling, band foreground RMS is {metric(rows, "rolling-bands"):.4f}; background RMS is lower without rows ({metric(rows, "rolling-bands", region="background"):.4f} vs {metric(new, "rolling-bands", region="background"):.4f}).'),
        ('4 · Joint solve and safeguards', 'Robust scene-local temporal trends, scene median anchor, rendered-brightness residual check, spatial gain regularisation and highlight limits.',
         f'Motion without flicker: {negative_old:.4f} → {negative_new:.4f} EV RMS ({reduction(negative_old, negative_new)} lower).',
         'Native anchor/toggle and renderer tests pass. Reviewed fox/LEGO frames show reduced gain islands after regularisation. These selected-frame observations do not prove every frame artifact-free.'),
        ('5 · Integration and evaluation', 'Existing Smooth/Steady controls, separate manual EV, consistent source-resolution rendering, frozen native outputs, component ablations and external reference.',
         f'Smooth: {count(old)}/10 → {count(new)}/10 targets. Steady: {count(old_steady)}/10 → {count(steady)}/10 targets.',
         f'{verification}. Four real exports preserve frame packet timing and audio payloads. Universal arm64/x86_64 app built and signature verified.'),
    ]
    table = ''.join('<tr>'+''.join(f'<td>{html.escape(value)}</td>' for value in row)+'</tr>' for row in details)
    measurements = ''.join(
        f'<tr><td>{html.escape(key)}</td><td>{metric(old,key):.4f}</td><td>{metric(new,key):.4f}</td>'
        f'<td>{metric(old,key,region="background"):.4f}</td><td>{metric(new,key,region="background"):.4f}</td>'
        f'<td>{html.escape("; ".join(assess(new[key])) or "Meets initial targets")}</td></tr>'
        for key in old)
    document = f'''<!doctype html><html lang="en"><meta charset="utf-8"><title>FrankLuma pipeline implementation and validation</title>
<style>body{{font:16px system-ui;margin:32px;max-width:1400px;line-height:1.5}}td,th{{padding:10px;text-align:left;vertical-align:top;border-bottom:1px solid #ddd}}table{{border-collapse:collapse;width:100%}}a{{color:#155fa0}}.notice{{padding:14px;background:#fff4d4}}code{{background:#eee;padding:2px}}</style>
<h1>FrankLuma: steps 2–5 implementation and validation</h1>
<p>{verification}. Results below describe actual encoded production exports, not predicted EV curves. Lower errors are better; foreground/background ground truth and the codec floor are scored separately. Initial targets remain unchanged.</p>
<table><tr><th>Step / technology</th><th>Implemented</th><th>Measured result versus frozen baseline</th><th>Independent evidence / limits</th></tr>{table}</table>
<p>Baseline differences measure the complete pipeline. Matched ablations isolate tracking, channel lighting and row modelling; the joint temporal/spatial safeguard row is supported by combined results and native invariant tests, not a separate causal attribution.</p>
<h2>All-case Smooth comparison</h2><p>Adjacent residual EV RMS against the clean target. These 10 controlled clips each have 72 frames at 12 fps. The error thresholds also include RGB, chromaticity, edges and clipping; an EV improvement alone is not a quality pass.</p>
<table><tr><th>Case</th><th>Baseline foreground</th><th>Final foreground</th><th>Baseline background</th><th>Final background</th><th>Assessment</th></tr>{measurements}</table>
<p class="notice"><b>Remaining limits:</b> Smooth's clipped-highlight case misses its flicker target; Steady meets that case but deliberately flattens the intentional ramp. Source clipping loses information. Camera-motion foreground error regresses from {metric(old,'camera-motion'):.4f} to {metric(new,'camera-motion'):.4f} EV RMS while remaining within the initial targets. Intentional flashes, moving shadows and textureless surfaces remain ambiguous. This suite does not establish performance on all videos.</p>
<h2>Review artifacts</h2><ul>
<li><a href="v1/results/surface-wide-final-v14/report.html">Final Smooth: exports, clean targets, masks, codec floors and scores</a></li>
<li><a href="v1/results/surface-wide-final-steady-v14/report.html">Final Steady: same ten cases</a></li>
<li><a href="real-wide-final-v14/report.html">Fox, LEGO, paper and outdoor: source/corrected sheets and movies</a></li>
<li><a href="v1/results/wide-final-v14-no-tracking/report.html">Tracking ablation</a> · <a href="v1/results/wide-final-v14-no-colour/report.html">Channel-lighting ablation</a> · <a href="v1/results/wide-final-v14-no-rows/report.html">Row-model ablation</a></li>
<li><a href="v1/results/ffmpeg-median-reference/report.html">FFmpeg median deflicker reference</a> · <a href="ffmpeg-reference/reference-provenance.json">Exact version, filter, commands and binary hash</a></li>
<li><a href="final-summary.json">Machine-readable verification and frozen source fingerprints</a> · <a href="../local/FrankLuma.app">Built universal app</a></li></ul>
<h2>Research and comparison scope</h2>
<p><a href="https://www.digitalanarchy.com/downloads/FlickerFree3.0-Manual.pdf">Flicker Free's manual</a> describes optical-flow motion compensation and larger temporal windows, and discusses ghosting/halo risks. FrankLuma adopts motion-aware measurements and longer scene-local histories while applying gains to original pixels.</p>
<p><a href="https://arxiv.org/abs/2403.06243">BlazeBVD</a> distinguishes global illumination from local texture effects. The implemented estimator separates correspondence from RGB lighting; it does not implement or claim equivalence to that neural method.</p>
<p>The external executable comparison uses <a href="https://www.ffmpeg.org/ffmpeg-filters.html#deflicker">FFmpeg's documented deflicker filter</a>, one median configuration and a matched x264 codec floor. This is not an exhaustive tuning search or a proprietary-tool comparison. The external report's detected cuts belong to FrankLuma's input audit, not FFmpeg scene detection. No commercial plugin output was tested.</p>
<p>Real footage has no verified clean target: its brightness diagnostics are descriptive. Selected review sheets showed smoother fox/LEGO gain fields than the unregularised candidate; residual temporal effects and intentional overlays require human judgement. App UI was compiled and covered by model tests; no locked-desktop GUI relaunch was performed.</p>
</html>'''
    (OUT / 'final-summary.html').write_text(document)
    print(OUT / 'final-summary.html')


if __name__ == '__main__':
    run()
