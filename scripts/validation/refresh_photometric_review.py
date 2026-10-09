"""Refresh candidate review from completed native evidence; never infer pending results."""
import html
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT/'dist/Benchmarks/general-review-v30'
p = OUT/'photometric-confidence-review.json'
report = json.loads(p.read_text())
sweep = json.loads((OUT/'photometric-confidence-slider-sweep.json').read_text())
report['sliderSweep'] = {key: sweep[key] for key in ['completedEncodedCases','expectedEncodedCases','pendingProfiles','complete']}
trials = []
folder = ROOT/'dist/Benchmarks/review-v31-photometric-confidence-fox-sliders'
for profile in ['strength-75','spatial-50','balanced']:
    case = folder/profile
    if not (case/'media-integrity.json').exists():
        continue
    integrity = json.loads((case/'media-integrity.json').read_text())
    assert integrity['passed']
    values = json.loads((case/'regional-brightness-check.json').read_text())
    n = sum(x['supportedFramePairs'] for x in values)
    trials.append({'profile':profile,'supportedPairs':n,'rmsEV':math.sqrt(sum(x['outputAdjacentRMSEV']**2*x['supportedFramePairs'] for x in values)/n) if n else None,
                   'peakEV':max(x['outputPeakStepEV'] for x in values) if n else None,'integrity':integrity})
report['foxSliderTrials'] = trials
report.pop('liveSweepSessionsAtReportTime',None)
p.write_text(json.dumps(report,indent=2)+'\n')
rows = ''
for case in report['realCases']:
    def value(side,key):
        n=case[side][key]
        return f'{n:.6f}' if n is not None else 'Unsupported'
    rows += f"<tr><td>{html.escape(case['case'])}</td><td>{value('before','rmsEV')} → {value('after','rmsEV')}</td><td>{value('before','peakEV')} → {value('after','peakEV')}</td></tr>"
trial_rows=''.join(f"<tr><td>{x['profile']}</td><td>{x['rmsEV']:.6f}</td><td>{x['peakEV']:.6f}</td></tr>" for x in trials)
text=f'''<!doctype html><meta charset="utf-8"><title>Photometric confidence review</title>
<style>body{{font:16px system-ui;max-width:1050px;margin:40px auto;padding:0 20px}}td,th{{padding:8px;border-bottom:1px solid #ccc}}img{{max-width:100%}}</style>
<h1>Photometric confidence review</h1><p>{html.escape(report['status'])}</p>
<p>Geometry matching uses wider texture and longer-baseline camera checks. Lighting retains raw photometric confidence. Rendering changes gains on original pixels without warping or blending frames.</p>
<p>{report['nativeTestsPassed']} native tests passed. {sweep['completedEncodedCases']}/450 encoded slider comparisons complete. {len(sweep['pendingProfiles'])} profiles pending. See <a href="photometric-confidence-slider-sweep.json">paired slider evidence</a>.</p>
<table><tr><th>Video</th><th>Regional RMS EV before → after</th><th>Peak step EV before → after</th></tr>{rows}</table>
<p>Before is retained app31 mathematics. Real footage has no clean reference; these measurements do not prove invisible flicker. Paper and outdoor footage lack supported regional comparisons. Fixed-screen measurements can mix composition and lighting during camera movement.</p>
<p>A source-selected matched-surface check of LEGO frames 83→84 measures median absolute log-RGB change of 0.11653 EV in source versus 0.02711 EV in the encoded correction across 15 footprints. This transition is substantially improved; the high fixed-screen peak did not establish worsening lighting. <a href="lego-matched-surface-step83-84.json">Matched evidence and limitations</a>.</p>
<h2>Fox slider checks</h2><table><tr><th>Setting</th><th>Regional RMS EV</th><th>Peak step EV</th></tr>{trial_rows}</table>
<p>Lower amounts deliberately retain more source variation. Slider settings are not ranked as universally best.</p>
<h2>Encoded frame samples</h2><p>Rows: source, retained correction, candidate. Columns: previous, selected, next frame.</p>
<img src="encoded-review/photometric-confidence-v1-fox169.png" alt="Fox frames 168 to 170"><img src="encoded-review/photometric-confidence-v1-fox349.png" alt="Fox frames 348 to 350">
<p><a href="photometric-confidence-review.json">Full evidence and build provenance</a></p>'''
(OUT/'photometric-confidence-review.html').write_text(text)
print('Review refreshed:',sweep['completedEncodedCases'],'slider cases;',len(trials),'verified Fox slider exports')
