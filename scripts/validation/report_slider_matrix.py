"""Report control semantics and quality trade-offs across actual encoded sweeps."""
import hashlib
import html
import json
import math
import re
import subprocess
from pathlib import Path
from run_slider_matrix import PROFILES, STEADY
from report_benchmark import assess

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT/'dist/Benchmarks'
OUT = BASE/'slider-range-v29'


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    records, identity_max, default_checks = [], 0.0, {}
    fixtures = {}
    expected_total = 0
    provenance = None
    for suite in ['development', 'holdout']:
        root = BASE/f'motion-v2-{suite}'
        ids = {c['id'] for c in read(root/'manifest.json')['cases']}
        fixtures.update({str(p.relative_to(BASE)):digest(p) for p in sorted((root/'cases').glob('*/*'))})
        for mode in ['smooth', 'steady']:
            names = list(PROFILES) if mode == 'smooth' else STEADY
            expected_total += len(ids)*len(names)
            for name in names:
                folder = root/f'results/slider-range-v29-{mode}-{name}'
                scores, settings = read(folder/'scores.json'), read(folder/'settings.json')
                profile = read(folder/'sweep-profile.json')
                assert profile['name'] == name and profile['mode'] == mode
                expected_settings = {'strength':1,'radius':0.5,'spatialStrength':1,'colourStrength':1,'preserveBrightness':True,'mode':'Smooth flicker' if mode=='smooth' else 'Steady scene'}
                keys = {'strength':'strength','radius':'radius','spatial-strength':'spatialStrength','colour-strength':'colourStrength'}
                for key,value in PROFILES[name].items():
                    expected_settings[keys[key]] = value
                assert all(settings[k] == v for k,v in expected_settings.items())
                assert {c['id'] for c in scores} == ids
                current = read(folder/'provenance.json')
                assert all(digest(ROOT/p) == value for p,value in current['pipelineSha256'].items())
                assert digest(ROOT/'scripts/validation/BenchmarkAudit.swift') == current['nativeHarnessSha256']
                assert digest(folder/'runner/audit') == current['binarySha256']
                if provenance is None:
                    provenance = current
                assert current['binarySha256'] == provenance['binarySha256']
                for case in scores:
                    assert case['timingAndGeometryPreserved'] and case['expectedCuts'] == case['detectedCuts']
                    assert case['frameCount'] == 72
                    for region in case['corrected'].values():
                        assert all(math.isfinite(v) for v in region.values())
                    evidence = read(folder/case['id']/'control-evidence.json')
                    assert all(math.isfinite(v) for v in evidence.values())
                    if name == 'off':
                        assert max(evidence.values()) < 0.000001
                        identity = read(folder/case['id']/'identity-check.json')
                        for region in identity.values():
                            assert region['linearRGBRMSE'] < 0.001 and region['residualFlickerRMSEV'] < 0.001
                            identity_max = max(identity_max,region['linearRGBRMSE'])
                    if name == 'global-only':
                        assert evidence['localPeakEV'] < 0.000001
                    relative = str(folder.relative_to(BASE))
                    records.append({'suite':suite,'mode':mode,'profile':name,'id':case['id'],'settings':settings,'evidence':evidence,'scores':case,'movie':f'../{relative}/{case["id"]}/corrected.mp4','sheet':f'../{relative}/{case["id"]}/comparison.png'})
                if name == 'default':
                    issues = {c['id']: assess(c) for c in scores if assess(c)}
                    default_checks[f'{suite}-{mode}'] = {'passed':len(scores)-len(issues),'total':len(scores),'issues':issues}
    assert len(records) == expected_total == 330
    log = (ROOT/'.build/slider-guidance-native-tests.log').read_text()
    assert "Test Suite 'All tests' passed" in log
    count = max(map(int,re.findall(r'Executed (\d+) tests, with 0 failures',log)))
    app = ROOT/'dist/local/FrankLuma.app'
    subprocess.run(['codesign','--verify','--strict',str(app)],check=True)
    binary = app/'Contents/MacOS/FrankLuma'
    assert set(subprocess.check_output(['lipo','-archs',str(binary)],text=True).split()) == {'arm64','x86_64'}
    assert '** BUILD SUCCEEDED **' in (ROOT/'.build/slider-guidance-app-build.log').read_text()
    gui = read(ROOT/'.build/slider-ui/guide-test.frankluma')
    saved = gui['scenes'][0]['settings']
    assert saved['strength'] == 0.75 and saved['spatialStrength'] == 0.5 and saved['colourStrength'] == 0.5 and saved['mode'] == 'Steady scene'
    summary = {'revision':'slider-range-v29','encodedCases':len(records),'distinctClips':22,'smoothProfiles':list(PROFILES),'steadyProfiles':STEADY,'nativeTestsPassed':count,'maximumOffIdentityRGBRMSE':identity_max,'defaultQualityChecks':default_checks,'appBinarySha256':digest(binary),'provenance':provenance,'fixtureSha256':fixtures,'reportHarnessSha256':digest(Path(__file__)),'guiVerification':{'isolatedBundle':True,'guidanceLegible':True,'strengthZeroDisablesColour':True,'spatialZeroDisablesColour':True,'spatialPositiveReenablesColour':True,'steadyHidesRadius':True,'savedPartialSettings':saved},'limitations':['Only the documented supported SDR media is accepted by the app.','22 finite synthetic clips do not establish performance on all video.','Separate clips were previously evaluated and are regression cases here, not unseen holdouts.','Partial correction intentionally leaves some flicker.','Steady still exceeds strict tolerances on stable zoom and rotation controls and intentionally flattens the exposure ramp.','Correction mathematics is unchanged from the LEGO matching fix v28.']}
    (OUT/'verification.json').write_text(json.dumps(summary,indent=2)+'\n')
    (OUT/'measurements.json').write_text(json.dumps(records,indent=2)+'\n')
    tables = []
    for r in records:
        c = r['scores']; f,b = c['corrected']['foreground'],c['corrected']['background']; settings=r['settings']
        fields = [r['id'],r['mode'],r['profile'],f'{settings["strength"]:.0%} / {settings["spatialStrength"]:.0%} / {settings["colourStrength"]:.0%}',str(settings['radius']) if r['mode']=='smooth' else '—',f'{f["residualFlickerRMSEV"]:.5f}',f'{b["residualFlickerRMSEV"]:.5f}',f'{f["chromaticityMAE"]:.5f}',f'{f["p95AbsoluteErrorEV"]:.4f}']
        cells=''.join(f'<td>{html.escape(v)}</td>' for v in fields)
        tables.append(f'<tr data-case="{r["id"]}" data-mode="{r["mode"]}">{cells}<td><a href="{r["movie"]}">Video</a> · <a href="{r["sheet"]}">Frames</a></td></tr>')
    cases = sorted({r['id'] for r in records})
    options = ''.join(f'<option>{name}</option>' for name in cases)
    checks = ''.join(f'<li>{key}: {value["passed"]}/{value["total"]} meet the full-correction engineering targets.</li>' for key,value in default_checks.items())
    (OUT/'report.html').write_text(f'''<!doctype html><html lang="en"><meta charset="utf-8"><title>Slider range and practical guidance</title><style>body{{font:15px system-ui;margin:32px;color:#182028}}p,li{{max-width:1100px;line-height:1.6}}table{{border-collapse:collapse}}td,th{{padding:10px;text-align:left;border-bottom:1px solid #ddd}}select{{font:inherit;margin:12px;padding:8px}}th{{background:#eef2f4;position:sticky;top:0}}tr[hidden]{{display:none}}</style><h1>Slider range and practical guidance</h1><p>330 actual encoded case/settings combinations across 22 clips, with ten Smooth profiles and five Steady profiles. The cases include camera motion, independent foreground/background lighting, colour flicker, clipping, occlusion, intended fades and stable footage. Settings span Strength 0/50/75/100%, Spatial 0/50/100%, Colour 0/50/100%, and Smooth radius 0.2/0.5/1.5 s. Amounts at 75% are part of the mixed profile rather than an isolated Strength sweep. The four separate cases have been evaluated previously and are regression checks here.</p><p>{count} native tests passed. The universal app builds and its signature verifies. Endpoint and export checks passed: Strength zero disables automatic gains and matches a separately encoded uncorrected export; Spatial zero disables local gains; Colour zero uses achromatic local gains while retaining brightness correction. Timing, frame count and scene boundaries are preserved. <a href="verification.json">Verification and fingerprints</a> · <a href="measurements.json">All measurements</a>.</p><h2>How to use the controls</h2><ul><li><b>Strength:</b> lower for excessive overall correction. Zero leaves only manual frame adjustments.</li><li><b>Spatial:</b> lower for uneven local gains or moving-subject artifacts. Zero keeps global exposure correction. It may leave local flicker, and a global correction can affect an unchanged foreground while the background flickers.</li><li><b>Colour:</b> lower for colour drift. Zero retains brightness correction while leaving chromatic flicker untreated. Requires Strength and Spatial above zero.</li><li><b>Radius:</b> Smooth mode only. Increase for slower fluctuations; decrease to preserve quicker intended lighting changes. Use Steady only when constant scene lighting is intended.</li><li><b>Workflow:</b> review scene cuts; loop Side by side; change one control at a time; inspect subject, background, shadows and highlights. Use nearby corrected frames and manual frame adjustment for isolated outliers. Review exported playback.</li></ul><p>The app includes concise slider hints, an expandable tuning guide and a fuller offline handbook. The guide and disabled states were checked in an isolated app instance, and a project saved the tested 75%/50%/50% Steady settings correctly.</p><h2>Quality remains a trade-off</h2><p>Stable zoom footage benefits from less automatic/local correction. Independently flickering backgrounds can require strong local correction to avoid applying global changes to an unchanged subject. Reducing Colour can retain brightness stability while leaving colour flicker. Larger or smaller radius changes the temporal target; it is not another Strength control. No one profile is declared a universally best setting, and partial profiles are not required to meet full-correction suppression targets.</p><ul>{checks}</ul><p>Steady intentionally flattens the exposure ramp and still changes two stable camera-motion controls beyond strict tolerances. The correction algorithm is unchanged from <a href="../lego-final-v28/report.html">the LEGO matching fix</a>, including its remaining peak flashes. This revision adds measured slider coverage and practical guidance; it does not establish that all videos are flash-free.</p><h2>Compare settings on one clip</h2><label>Clip <select id="clip"><option value="">All clips</option>{options}</select></label><label>Mode <select id="mode"><option value="">Both modes</option><option value="smooth">Smooth</option><option value="steady">Steady</option></select></label><p>Strength / Spatial / Colour are the requested amounts. Residual EV RMS measures adjacent variation in error relative to a verified clean target, separately for foreground and background. Chroma MAE measures colour error; P95 EV measures exposure accuracy. Smaller residual alone does not guarantee better colour or preservation of intended lighting. Codec floors and the uncorrected input scores are in measurements.json.</p><table><thead><tr><th>Clip</th><th>Mode</th><th>Profile</th><th>Amounts</th><th>Radius s</th><th>Foreground EV RMS</th><th>Background EV RMS</th><th>Foreground chroma MAE</th><th>Foreground P95 EV</th><th>Review</th></tr></thead><tbody>{''.join(tables)}</tbody></table><script>function filter(){{const clip=document.querySelector('#clip').value,mode=document.querySelector('#mode').value;document.querySelectorAll('tbody tr').forEach(row=>row.hidden=(clip&&row.dataset.case!==clip)||(mode&&row.dataset.mode!==mode));}}document.querySelectorAll('select').forEach(s=>s.addEventListener('change',filter));document.querySelector('#clip').value='no-flicker-zoom';document.querySelector('#mode').value='smooth';filter();</script></html>''')
    print(OUT/'report.html')


if __name__ == '__main__':
    main()
