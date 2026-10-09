"""Publish measured candidate evidence, preserving failures and build identities."""
import hashlib
import html
import json
import math
from pathlib import Path
from run_slider_matrix import PROFILES, STEADY
from report_benchmark import assess

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT/'dist/Benchmarks'
OUT = BASE/'general-review-v30'


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def regional(path):
    values = read(path)
    n = sum(x['supportedFramePairs'] for x in values)
    return {'supportedPairs': n,
            'rms': math.sqrt(sum(x['outputAdjacentRMSEV']**2*x['supportedFramePairs'] for x in values)/n) if n else None,
            'peak': max((x['outputPeakStepEV'] for x in values), default=None) if n else None}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    assert "Test Suite 'All tests' passed" in (ROOT/'.build/review-v30/final-timing-full-tests.log').read_text()
    provenance = read(ROOT/'.build/review-v30/stage13-runner/build-provenance.json')
    compiled = ['Exposure','Scenes','PatchExposure','SpatialLighting','SpatialRenderer','VideoGeometry','VideoEngine','VideoExporter']
    for name in compiled:
        key = f'Sources/FrankLuma/{name}.swift'
        assert digest(ROOT/f'.build/review-v30/algorithm13/sources/{name}.swift') == provenance['pipelineSha256'][key]
    records, defaults, table = [], {}, []
    for suite, dataset, revision in [('development','motion-v2-development','v30-candidate13'),
                                     ('separate-regression','motion-v2-holdout','v30-candidate13'),
                                     ('adversarial','adversarial-v30','v30-candidate13-final')]:
        root = BASE/dataset
        ids = {x['id'] for x in read(root/'manifest.json')['cases']}
        for mode in ['smooth','steady']:
            for profile in (PROFILES if mode == 'smooth' else STEADY):
                folder = root/f'results/slider-range-{revision}-{mode}-{profile}'
                scores, settings = read(folder/'scores.json'), read(folder/'settings.json')
                build = read(folder/'provenance.json')
                assert build['binarySha256'] == provenance['binarySha256'] == digest(folder/'runner/audit')
                assert build['pipelineSha256'] == provenance['pipelineSha256']
                assert {x['id'] for x in scores} == ids
                if profile == 'default':
                    defaults[f'{suite}-{mode}'] = {x['id']: assess(x) for x in scores}
                for case in scores:
                    assert case['timingAndGeometryPreserved'] and case['detectedCuts'] == case['expectedCuts']
                    evidence = read(folder/case['id']/'control-evidence.json')
                    identity = read(folder/case['id']/'identity-check.json') if profile == 'off' else None
                    if identity:
                        assert max(evidence.values()) < 1e-6
                        assert all(x['linearRGBRMSE'] < .001 and x['residualFlickerRMSEV'] < .001 for x in identity.values())
                    if profile == 'global-only': assert evidence['localPeakEV'] < 1e-6
                    old_folder = root/f'results/slider-range-v29-{mode}-{profile}'
                    old = next((x for x in read(old_folder/'scores.json') if x['id'] == case['id']), None) if (old_folder/'scores.json').exists() else None
                    if suite == 'adversarial' and profile == 'default' and mode == 'smooth':
                        old = next(x for x in read(root/'results/reference-v29/scores.json') if x['id'] == case['id'])
                    rel = folder.relative_to(BASE)
                    entry = {'suite':suite,'mode':mode,'profile':profile,'case':case['id'],'settings':settings,
                             'scores':case,'before':old,'controlEvidence':evidence,'identity':identity,
                             'movie':f'../{rel}/{case["id"]}/corrected.mp4','sheet':f'../{rel}/{case["id"]}/comparison.png'}
                    records.append(entry)
                    fg,bg = [case['corrected'][k]['residualFlickerRMSEV'] for k in ['foreground','background']]
                    prior = '—' if old is None else f'{old["corrected"]["foreground"]["residualFlickerRMSEV"]:.5f}'
                    table.append(f'<tr data-case="{case["id"]}" data-mode="{mode}" data-profile="{profile}"><td>{case["id"]}</td><td>{mode}</td><td>{profile}</td><td>{prior}</td><td>{fg:.5f}</td><td>{bg:.5f}</td><td><a href="{entry["movie"]}">Encoded video</a> · <a href="{entry["sheet"]}">Frames</a></td></tr>')
    assert len(records) == 450
    manifest = read(ROOT/'scripts/validation/benchmark-real-cases.json')
    real, rows = [], []
    for case in manifest['cases']:
        for mode in ['smooth','steady']:
            folder = BASE/'review-v30-stage13-real'/case['id']/mode
            metrics = regional(folder/'regional-brightness-check.json')
            prior = None
            if case['id'] in ['lego-4k','fox-three-scenes']:
                old_case = ('lego' if case['id'] == 'lego-4k' else 'fox') if mode == 'steady' else case['id']
                old = BASE/('lego-final-v28' if mode == 'steady' else 'lego-final-v28-smooth')/old_case/'regional-brightness-check.json'
                prior = regional(old)
                assert prior['supportedPairs'] == metrics['supportedPairs']
            if case['id'] == 'clay-armature' and mode == 'smooth':
                prior = regional(BASE/'review-v30-clay-reference/smooth/regional-brightness-check.json')
            source = Path(case['source']);source = source if source.is_absolute() else ROOT/source
            current = BASE/'review-v30-final-timing-real'/case['id']/mode
            checked = read(current/'media-integrity.json') if (current/'media-integrity.json').exists() else None
            entry = {**case,'mode':mode,'sourceSha256':digest(source),'metrics':metrics,'before':prior,
                     'integrityAfterTimescaleFix':checked,'correctedMovie':str((folder/'corrected.mp4').relative_to(BASE)),
                     'qualityGroundTruth':None}
            real.append(entry)
            fmt = lambda x: 'No supported comparison' if x is None else f'{x:.5f}'
            rows.append(f'<tr><td>{case["id"]}</td><td>{mode}</td><td>{fmt(prior["rms"] if prior else None)}</td><td>{fmt(metrics["rms"])}</td><td>{fmt(prior["peak"] if prior else None)}</td><td>{fmt(metrics["peak"])}</td><td><a href="../{entry["correctedMovie"]}">Encoded video</a></td></tr>')
    quality_issues = {suite:{case:issues for case,issues in values.items() if issues} for suite,values in defaults.items()}
    result = {'status':'Development evidence; known difficult cases still need work','encodedSliderCombinations':450,
              'syntheticClips':30,'realClips':5,'qualityGroundTruthForRealClips':None,'defaultQualityIssues':quality_issues,
              'testedBuild':provenance,'tests':{'productionPassed':134,'log':'.build/review-v30/final-timing-full-tests.log',
                  'debugWorkflowPassed':2,'debugLog':'.build/review-v30/stage13-debug-completion-tests.log'},
              'records':records,'real':real,
              'laterExporterChange':'Separately tested edit-list timescale fix; current integrity reports are linked per real export.'}
    (OUT/'measurements.json').write_text(json.dumps(result,indent=2)+'\n')
    (OUT/'attribution.txt').write_text((ROOT/'PracticeFootage/README.md').read_text())
    issues = ''.join(f'<li><b>{html.escape(suite)}</b>: {html.escape(json.dumps(values))}</li>' for suite,values in quality_issues.items() if values)
    options = ''.join(f'<option>{x}</option>' for x in sorted({r['case'] for r in records}))
    page = '''<!doctype html><html lang="en"><meta charset="utf-8"><title>FrankLuma general correction review</title>
<style>body{font:16px system-ui;margin:32px;color:#182028;max-width:1600px}p,li{line-height:1.6;max-width:1150px}table{border-collapse:collapse;width:100%}td,th{padding:9px;text-align:left;border-bottom:1px solid #ddd}th{background:#edf2f5;position:sticky;top:0}select{font:inherit;margin:8px;padding:8px}.notice{background:#fff1cc;padding:16px}tr[hidden]{display:none}</style>
<h1>FrankLuma general correction review</h1><p class="notice"><b>Development evidence, with remaining limitations.</b> This measures the candidate against the preceding engine. It does not establish that every clip is flash-free, or that it matches commercial tools.</p>
<p>450 actual encoded settings combinations on 30 self-generated clips, plus five real stop-motion clips. The eight longer adversarial clips and the CC0 clay film expand coverage beyond the previous demos. Cases evaluated during tuning are regression evidence, not untouched holdouts.</p>
<p><a href="measurements.json">Measurements, failures and build fingerprints</a> · <a href="attribution.txt">Footage attribution</a>. All 450 synthetic settings runs preserve frame timing, dimensions and expected cuts. Strength zero matches an independent no-op encode; Spatial zero disables local gains; Colour zero keeps gains achromatic. The production suite passed 134 tests; two debug workflow tests also passed after setup waited for analysis completion. A subsequent export-timescale correction has its own fixture and per-export integrity evidence.</p>
<h2>What improved—and what did not</h2><ul><li>Fox Smooth: regional RMS approximately 10% lower; largest regional step approximately 33% smaller.</li><li>Fox Steady: regional RMS approximately 3% lower; largest regional step approximately 16% smaller.</li><li>Rolling bands: foreground residual RMS approximately 20% lower at full Smooth correction.</li><li>Background-only flash at 50% Spatial: foreground error 0.128 → 0.026 EV RMS. More background variation remains, consistent with reduced local correction.</li><li>LEGO: no clear default improvement. Steady regional RMS increases approximately 3%, and the largest step approximately 2%. Reduced settings are not automatically better.</li><li>Independent foreground/background lighting still exceeds the initial foreground-error targets. Steady can remove intentional fades and still affects some stable camera controls.</li></ul>
<h2>How this compares with published approaches</h2><p><a href="https://www.digitalanarchy.com/downloads/FlickerFree3.0-Manual.pdf">Flicker Free</a> documents neighbouring-frame analysis, optical-flow motion compensation, temporal radius and thresholds. <a href="https://revisionfx.com/products/deflicker/">RE:Vision DEFlicker</a> advertises high-speed lighting and timelapse correction. <a href="https://lrtimelapse.com/tutorial/basic/complete/">LRTimelapse</a> documents reference regions, smoothing and repeated rendered-result checks. These are descriptions and manufacturer claims; no identical-footage commercial-tool benchmark was performed.</p>
<p>The candidate separates shared exposure from local illumination, connects supported fragment histories, retains validated shared targets, preserves source geometry, and validates bounded gain refinement on separate source-pixel footprints after Colour projection. Experimental correspondence variants that regressed controls were rejected. The most important remaining gap is reliable photometry on small moving surfaces under independent lights.</p>
<h2>Use the sliders deliberately</h2><ul><li><b>Strength:</b> reduce excessive overall correction. Zero disables automatic correction while retaining manual edits.</li><li><b>Spatial:</b> controls local deviations from supported shared lighting. Lower it for uneven local changes; expect more local flicker to remain. Watch the subject and background separately.</li><li><b>Colour:</b> reduce colour drift without treating it as a second brightness-strength control. Zero leaves brightness correction achromatic.</li><li><b>Radius:</b> changes the timescale smoothed in Smooth mode. Larger values can suppress slower fluctuations but also flatten intended changes.</li><li><b>Steady:</b> use when constant lighting is intended. Review fades and camera reveals carefully.</li><li>Loop Side by side, change one control at a time, inspect nearby frames, and check the encoded export. Manual frame EV remains available for isolated outliers.</li></ul>
<h2>Real footage: descriptive measurements</h2><p>Regional RMS and peaks include composition, motion and shadows. These clips have no clean ground truth; lower numbers alone do not prove better correction. “No supported comparison” is missing evidence, not zero error. The clay film is <a href="https://commons.wikimedia.org/wiki/File:Stop-Motion_Animation_(Basic).webm">Teja Silaparasetty’s CC0 stop motion</a>. Attribution and hashes accompany the derivatives.</p>
<table><tr><th>Clip</th><th>Mode</th><th>Previous RMS EV</th><th>Candidate RMS EV</th><th>Previous peak EV</th><th>Candidate peak EV</th><th>Review</th></tr>'''+''.join(rows)+'''</table>
<p><a href="photometry-experiments.html">Later material-photometry experiments</a>: 65 additional encoded comparisons. All three variants were rejected for defaults because improvements on independent lights came with regressions elsewhere; the candidate engine above remains the restored baseline.</p>
<p><a href="short-track-experiments.html">Later short-track experiments</a>: 46 encoded synthetic comparisons and two real exports. The graph solver passes its controlled tests but provides no meaningful new LEGO or Fox gain; it remains disabled by default.</p>
<p><a href="gain-boundary-experiments.html">Lighting-boundary smoothing experiment</a> and <a href="anchored-smoothing-experiments.html">confidence-anchored smoothing experiment</a>: each includes 26 encoded synthetic cases and separate LEGO and Fox exports. Stage reconstruction confirms that smoothing can reverse a local correction. Both variants improve selected independent-light cases but regress other cases; neither is enabled in the app. The anchored implementation was archived and removed from the active source because matching confidence does not establish exposure reliability.</p>
<p><a href="supported-smoothing-experiments.html">Independently supported smoothing experiment</a>: 26 encoded synthetic cases and separate LEGO and Fox exports. Requiring repeated RGB changes and three independent observation cells improves moving local-light RMS 24% and mixed-light RMS 6%, but Fox peak steps regress 10%. It was archived and removed from active source; independent histories still need stronger checks against correlated appearance changes.</p>
<p><a href="smooth-patch-validation-v1.html">Smooth patch validation, first version</a> reduces Fox regional RMS about 21%, its largest step about 42%, and LEGO RMS about 7%, but regresses zoom and rotation. <a href="smooth-patch-validation-v2.html">The guarded version</a> avoids those motion regressions but also disables the real-video gains. Each version was tested on 26 encoded synthetic cases and two real exports; both remain experimental and are not enabled in the app.</p>
<p><a href="smooth-patch-validation-v3.html">Contrast-normalised background proof</a> retains Fox's roughly 21% RMS and 42% peak-step improvement while preserving the default zoom, rotation and clean-motion benchmark results. LEGO is essentially unchanged. All <a href="smooth-patch-slider-sweep.json">450 paired slider cases</a> passed integrity/control checks; all 143 native tests passed again after enabling the production default. Five real videos and three additional Fox slider trials passed exact media checks. It is enabled in the separate signed universal review build 31; the original running app was not replaced. Residual flashes and mixed-lighting limitations remain.</p>
<p><a href="arithmetic-photometry-experiments.html">Subsequent linear-light photometry experiments</a>: 36 encoded synthetic comparisons and three real exports. Plane-corrected averaging passes its contrast and gradient tests, but produces no useful LEGO improvement and several regressions. Both variants were archived and removed from active source; verified build 31 remains the retained engine.</p>
<p><a href="short-scene-geometry-review.html">Short-scene and geometry validation review</a>: 54 encoded synthetic comparisons and four real exports. Short-shot colour gating worsens LEGO under fixed original measurement support. Frame-level geometry validation offers only a small LEGO gain; patch-level validation worsens Fox despite 143 passing native tests. All three prototypes were rejected and source restored. The next investigation is tracking correspondence under changing illumination.</p>
<p><a href="contrast-tracking-review.html">Contrast tracking and slow-zoom review</a>: 120 encoded synthetic comparisons and 15 real exports. Longer-baseline camera evidence preserves zoom controls, but clipping introduces a trade-off between Fox gains and highlight-stress errors. All six variants were rejected; retained build31 remains unchanged.</p>
<p><a href="photometric-confidence-review.html">Separate geometry and lighting confidence</a> passed all 450 paired encoded slider cases and exact media checks on five real exports plus three Fox slider trials. It is enabled in source; the separate review app build is tracked in the linked report. Fox peak step is about 26% lower than retained app31 mathematics; LEGO remains essentially unchanged. Small highlight-stress trade-offs and unresolved mixed-light and LEGO flashes are recorded.</p>
<p>The <a href="matched-luminance-review.html">source-selected matched-luminance audit</a> measures the actual encoded output on corresponding texture footprints, with explicit unsupported coverage. Compared with source, RMS of transition median absolute luminance steps falls about 65% on LEGO and 94% on Fox. These are different metrics from fixed-screen regions and compare current correction with source, rather than isolating the latest revision. LEGO frames 168→169 remain a supported regression; global gain and the brightness safeguard both contribute to that jump.</p>
<h2>Initial quality targets that remain unmet</h2><p>Targets and codec floors are retained from the benchmark. Partial settings are intentionally not required to suppress flicker as strongly as full settings.</p><ul>'''+issues+'''</ul>
<h2>Compare encoded settings</h2><p>Foreground and background RMS are adjacent variation in error relative to the independently generated clean frame. Smaller is better, but inspect exposure, colour and edges too. Previous foreground values are available for the earlier 22-clip sweep and new Smooth defaults; other entries have no identical-profile baseline.</p><label>Clip <select id="clip"><option value="">All</option>'''+options+'''</select></label><label>Mode <select id="mode"><option value="">Both</option><option value="smooth">Smooth</option><option value="steady">Steady</option></select></label><table><thead><tr><th>Clip</th><th>Mode</th><th>Profile</th><th>Previous foreground RMS</th><th>Candidate foreground RMS</th><th>Candidate background RMS</th><th>Review</th></tr></thead><tbody>'''+''.join(table)+'''</tbody></table><script>function filter(){let c=document.querySelector('#clip').value,m=document.querySelector('#mode').value;document.querySelectorAll('tbody tr').forEach(r=>r.hidden=(c&&r.dataset.case!==c)||(m&&r.dataset.mode!==m));}document.querySelectorAll('select').forEach(s=>s.addEventListener('change',filter));document.querySelector('#clip').value='local-moving';document.querySelector('#mode').value='smooth';filter();</script></html>'''
    (OUT/'report.html').write_text(page)
    print(OUT/'report.html')


if __name__ == '__main__': main()
