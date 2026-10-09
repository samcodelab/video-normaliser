"""Render measured candidate evidence without hiding incomplete validation."""
import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'dist/Benchmarks/general-review-v30'
review = json.loads((OUT / 'registered-anchor-review.json').read_text())
sweep = json.loads((OUT / 'registered-anchor-slider-sweep.json').read_text())
log = (ROOT / '.build/review-v32/registered-anchor-experiment/full-tests-v2.log').read_text()
suite = re.search(r"Test Suite 'All tests' passed[^\n]*\n\s*Executed (\d+) tests, with 0 failures", log)
native_status = f'{suite.group(1)} native tests passed.' if suite else 'Full native suite pending.'
real_exports = ROOT / 'dist/Benchmarks/review-v32-registered-anchor-real'
for name in ['lego', 'fox', 'clay-armature', 'paper-animation', 'outdoor-pixilation']:
    assert json.loads((real_exports / name / 'smooth/media-integrity.json').read_text())['passed']
for profile in review['realSliderReview']['profiles']:
    assert all(r['passed'] for r in profile['mediaIntegrity'].values())
assert json.loads((ROOT / 'dist/Benchmarks/review-v32-registered-anchor-v2-lego/smooth/media-integrity.json').read_text())['passed']
lego = review['legoMatchedLuminance']
target = next(t for t in lego['transitions'] if t['frames'] == [168, 169])
rows = [('LEGO', len(lego['transitions']), lego['beforeRMS'], lego['afterRMS'])]
rows += [(r['case'], r['supportedTransitions'], r['beforeRMS'], r['afterRMS'])
         for r in review['otherRealMatchedLuminance']]
table = ''.join(f'<tr><td>{html.escape(name)}</td><td>{count}</td><td>{before:.5f}</td><td>{after:.5f}</td></tr>'
                for name, count, before, after in rows)
profiles = ''.join(f"<tr><td>{html.escape(r['profile'])}</td><td>{r['target']['before']:.5f}</td><td>{r['target']['after']:.5f}</td><td>{r['largestOtherIncreaseEV']:.5f}</td></tr>"
                   for r in review['realSliderReview']['profiles'])
text = f'''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Registered-camera correction review</title>
<style>body{{font:16px system-ui;max-width:1000px;margin:40px auto;padding:0 20px;line-height:1.55;color:#222}}table{{border-collapse:collapse;width:100%;margin:20px 0}}th,td{{text-align:left;padding:10px;border-bottom:1px solid #ddd}}.status{{background:#fff3ce;padding:16px}}img{{max-width:100%;height:auto}}</style>
<h1>Registered-camera correction review</h1>
<p class="status">{html.escape(review['status'])} Slider sweep: {sweep['completedEncodedCases']}/{sweep['expectedEncodedCases']} encoded cases complete. {native_status}</p>
<p>The candidate follows corresponding source textures during camera movement and reduces manufactured exposure differences only where the original surfaces have small brightness changes. It modifies scalar exposure gains; it does not blend or warp image pixels.</p>
<p>LEGO's 168→169 brightness step falls from {target['before']:.5f} to {target['after']:.5f} EV. Overall supported-transition RMS improves by {(1-lego['afterRMS']/lego['beforeRMS'])*100:.1f}%.</p>
<table><thead><tr><th>Video</th><th>Supported transitions</th><th>Before RMS (EV)</th><th>Candidate RMS (EV)</th></tr></thead><tbody>{table}</tbody></table>
<p>Before means the retained app32 algorithm at identical settings. These figures describe median absolute changes of corresponding, source-selected linear-luminance footprints. Missing support and scene cuts are excluded. Overlapping footprints are not independent samples, and no clean lighting reference establishes perceptual accuracy.</p>
<h2>Reduced slider settings</h2><table><thead><tr><th>Profile</th><th>Target before (EV)</th><th>Target after (EV)</th><th>Largest transition increase (EV)</th></tr></thead><tbody>{profiles}</tbody></table>
<p>The small increases remain visible in the evidence. Lower residual variation alone cannot distinguish a legitimate source lighting change from flicker.</p>
<h2>Encoded frame comparison</h2><p>Columns: frames 168, 169, 170. Rows: original, retained app32, candidate. This sample is not a whole-video visual review.</p>
<img src="encoded-review/registered-anchor-v1-lego169.png" alt="Original and corrected LEGO frames around the brightness jump">
<p>Native targeted tests: {review['surfaceTrackingTestsPassed']} surface-tracking and {review['rendererTestsPassed']} renderer tests passed. Timing, audio and geometry checks pass for the five real candidate exports and six paired partial-slider LEGO exports.</p>
<p><a href="registered-anchor-review.json">Detailed evidence</a> · <a href="registered-anchor-slider-sweep.json">Slider sweep</a> · <a href="registered-anchor-real-sliders.json">Paired real slider measurements</a></p>
</html>'''
(OUT / 'registered-anchor-review.html').write_text(text)
print(OUT / 'registered-anchor-review.html')
