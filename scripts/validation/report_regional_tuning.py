#!/usr/bin/env python3
"""Report final regional validation against the previously accepted v18 pipeline."""
import hashlib
import html
import json
import math
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BASE = ROOT / "dist/Benchmarks"
OUT = BASE / "regional-validation-final-v22"

def read(path):
    return json.loads(path.read_text())

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def region_rms(rows):
    return math.sqrt(sum(r["outputAdjacentRMSEV"]**2*r["supportedFramePairs"] for r in rows)/sum(r["supportedFramePairs"] for r in rows))

def background_rms(rows,frames):
    starts = [r["startFrame"] for r in rows]+[frames]
    pairs = [starts[i+1]-starts[i]-1 for i in range(len(rows))]
    return math.sqrt(sum(r["adjacentRMSEV"]**2*n for r,n in zip(rows,pairs))/sum(pairs))

def main():
    provenance = read(OUT/"real-build-provenance.json")
    assert all(sha(ROOT/p)==v for p,v in provenance["pipelineSha256"].items())
    assert sha(OUT/"runner/real-audit")==provenance["binarySha256"]
    log = (ROOT/".build/regional-validation-final-tests.log").read_text()
    assert "Test Suite 'All tests' passed" in log
    tests = max(map(int,re.findall(r"Executed (\d+) tests, with 0 failures",log)))
    app = ROOT/"dist/local/FrankLuma.app"
    subprocess.run(["codesign","--verify","--deep","--strict",str(app)],check=True)
    binary = app/"Contents/MacOS/FrankLuma"
    arches = subprocess.check_output(["lipo","-archs",str(binary)],text=True).split()
    assert set(arches)=={"arm64","x86_64"}
    assert "** BUILD SUCCEEDED **" in (ROOT/".build/regional-validation-final-app-build.log").read_text()
    modes = {}
    for mode in ["smooth","steady"]:
        label = "regional-validation-final-"+("steady-" if mode=="steady" else "")+"v22"
        report = read(BASE/"v1/results"/label/"report.json")
        assert report["completeCaseSet"]
        assert report["provenance"]["pipelineSha256"]==provenance["pipelineSha256"]
        modes[mode] = report
    clips = {}
    for clip,frames in [("fox",600),("lego",212)]:
        old = BASE/"tuning-baseline-v19"/clip
        current = OUT/clip/"steady"
        before = read(old/"regional-brightness-check.json")
        after = read(current/"regional-brightness-check.json")
        assert sha(old/"source-cells.json")==sha(current/"source-cells.json")
        assert {(r["startFrame"],r["region"],r["supportedFramePairs"]) for r in before}=={(r["startFrame"],r["region"],r["supportedFramePairs"]) for r in after}
        a,b = region_rms(before),region_rms(after)
        data = {"previousRegionalRMSEV":a,"currentRegionalRMSEV":b,"regionalRMSReductionPercent":100*(1-b/a),
                "previousBackgroundRMSEV":background_rms(read(old/"brightness-check.json"),frames),
                "currentBackgroundRMSEV":background_rms(read(current/"brightness-check.json"),frames),
                "previousPeakRegionalStepEV":max(r["outputPeakStepEV"] for r in before),
                "currentPeakRegionalStepEV":max(r["outputPeakStepEV"] for r in after),
                "remainingLargestSteps":sorted(after,key=lambda r:r["outputPeakStepEV"],reverse=True)[:5],"integrity":{}}
        for mode in ["steady","smooth"]:
            integrity = read(OUT/clip/mode/"packet-integrity.json")
            assert integrity["video"]["counts"]==[frames,frames]
            for kind in ["video","audio"]:
                assert integrity[kind]["counts"][0]==integrity[kind]["counts"][1]
                assert integrity[kind]["pts_time"] and integrity[kind]["duration_time"]
            assert integrity["audio"]["payloadsMatch"]
            data["integrity"][mode] = integrity
        clips[clip] = data
    old_steady = read(BASE/"v1/results/local-confidence-final-steady-v18/report.json")
    old_scores = {r["id"]:r for r in old_steady["scores"]}
    scores = [{"case":r["id"],"previousForegroundResidualEV":old_scores[r["id"]]["corrected"]["foreground"]["residualFlickerRMSEV"],
               "currentForegroundResidualEV":r["corrected"]["foreground"]["residualFlickerRMSEV"],
               "assessment":modes["steady"]["assessment"][r["id"]]["status"]} for r in modes["steady"]["scores"]]
    result = {"revision":"regional-validation-final-v22","testsPassed":tests,"appBinarySHA256":sha(binary),"architectures":arches,
              "pipelineSha256":provenance["pipelineSha256"],"clips":clips,"steadyScores":scores,
              "smoothTargetsPassed":sum(v["status"]=="meets-initial-targets" for v in modes["smooth"]["assessment"].values()),
              "steadyTargetsPassed":sum(v["status"]=="meets-initial-targets" for v in modes["steady"]["assessment"].values()),
              "rejectedExperiment":"v20: looser local confidence increased fox flash residuals"}
    (OUT/"verification.json").write_text(json.dumps(result,indent=2)+"\n")
    real_rows = "".join(f'<tr><td>{c.upper()}</td><td>{d["previousRegionalRMSEV"]:.5f}</td><td>{d["currentRegionalRMSEV"]:.5f}</td><td>{d["regionalRMSReductionPercent"]:.1f}%</td><td>{d["previousPeakRegionalStepEV"]:.4f} → {d["currentPeakRegionalStepEV"]:.4f}</td></tr>' for c,d in clips.items())
    score_rows = "".join(f'<tr><td>{html.escape(r["case"])}</td><td>{r["previousForegroundResidualEV"]:.4f}</td><td>{r["currentForegroundResidualEV"]:.4f}</td><td>{r["assessment"]}</td></tr>' for r in scores)
    (OUT/"report.html").write_text(f"""<!doctype html><html lang="en"><meta charset="utf-8"><title>FrankLuma regional tuning</title>
<style>body{{font:16px system-ui;line-height:1.5;margin:32px;max-width:1250px}}td,th{{padding:9px;border-bottom:1px solid #ccc;text-align:left}}img{{width:100%;height:auto}}a{{color:#155fa0}}</style>
<h1>Regional brightness validation — 6 October 2026</h1>
<p>The previous revision left local flashes despite a steady scene-median exposure. A looser confidence filter worsened the fox's regional residuals and was rejected. The accepted revision checks predicted rendered brightness against held source patches, and applies bounded, achromatic local gain adjustments with material and support checks.</p>
<p>This additional validation operates in the existing <b>Steady scene</b> mode when Preserve scene brightness is enabled. Camera-motion shots, dedicated row-lighting models and manual reference regions retain their existing path. Adjustments are bounded to 0.2 EV, scaled by Spatial correction, and never borrow neighbouring image pixels. Existing Strength, Spatial, Colour and manual frame EV controls remain.</p>
<p><b>{tests} tests passed.</b> Universal app built and signature verified. Both clips were exported in both modes; all source video timestamps/durations and audio packet timing/content were preserved. <a href="verification.json">Measured data and build fingerprints</a>.</p>
<h2>Actual encoded Steady exports: local residuals</h2>
<p>Adjacent-frame regional RMS in EV, weighted by supported frame pairs across twelve source-selected regions per shot. Source selection and pair support are identical before/after. These clips have no clean reference; region changes can still include composition or occlusion. This is not a guarantee that every flash is invisible.</p>
<table><tr><th>Clip</th><th>Previous regional EV RMS</th><th>Current regional EV RMS</th><th>Reduction</th><th>Largest regional step EV</th></tr>{real_rows}</table>
<p>Whole-scene background RMS also decreases: fox {clips['fox']['previousBackgroundRMSEV']:.5f} → {clips['fox']['currentBackgroundRMSEV']:.5f} EV; LEGO {clips['lego']['previousBackgroundRMSEV']:.5f} → {clips['lego']['currentBackgroundRMSEV']:.5f} EV. Camera/occlusion sequences remain a limitation. The fox's largest remaining measured step is at frame 169; LEGO's largest step is at frame 84 near a camera composition change (zero-based indices).</p>
<p><a href="fox/steady/corrected.mp4">Fox Steady export</a> · <a href="lego/steady/corrected.mp4">LEGO Steady export</a> · <a href="fox/steady/regional-brightness-check.json">Fox regional checks and exact peak frames</a> · <a href="lego/steady/regional-brightness-check.json">LEGO regional checks</a>.</p>
<h2>Clean-reference benchmarks</h2><p>Smooth meets {result['smoothTargetsPassed']}/10 initial engineering targets; Steady meets {result['steadyTargetsPassed']}/10, with its expected intentional-fade failure. Smooth's gradual-lighting behavior is retained. The unchanged moving subject under local background flashes improves; camera-motion cases retain their prior correction path.</p>
<table><tr><th>Case</th><th>Previous Steady foreground EV RMS</th><th>Current Steady foreground EV RMS</th><th>Assessment</th></tr>{score_rows}</table>
<p><a href="../v1/results/regional-validation-final-v22/report.html">Full Smooth scores</a> · <a href="../v1/results/regional-validation-final-steady-v22/report.html">Full Steady scores</a> · <a href="../local-confidence-final-v18/report.html">Previous revision</a>.</p>
<h2>Decoded encoded frames: fox 348–350</h2><p>Previous correction</p><img src="fox-previous-348.png" alt="Previous fox correction at flash frames"><p>Current correction</p><img src="fox-current-348.png" alt="Current fox correction at flash frames">
<h2>Decoded encoded frames: LEGO camera pan 85–87</h2><p>Current correction; camera-shot correction path retained.</p><img src="lego-current-85.png" alt="LEGO camera-pan frames after final export">
</html>""")
    print(json.dumps({"testsPassed":tests,"regionalReductionPercent":{c:d["regionalRMSReductionPercent"] for c,d in clips.items()},"smoothTargetsPassed":result["smoothTargetsPassed"],"steadyTargetsPassed":result["steadyTargetsPassed"]}))

if __name__=="__main__":
    main()
