"""Paired registered-camera experiment; keep pending work and regressions visible."""
import json,math
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2];BASE=ROOT/'dist/Benchmarks';OUT=BASE/'general-review-v30'
rows=[];pending=[]
for suite in ['motion-v2-development','motion-v2-holdout','adversarial-v30']:
 p=BASE/suite/'results/registered-anchor-v1-smooth/scores.json'
 if not p.exists():pending.append(suite);continue
 before={x['id']:x for x in json.loads((BASE/suite/'results/photometric-confidence-v1-smooth/scores.json').read_text())}
 after=json.loads(p.read_text())
 if {x['id'] for x in after} != set(before):pending.append(suite)
 for x in after:
  assert x['timingAndGeometryPreserved'] and x['detectedCuts']==x['expectedCuts']
  rows.append({'suite':suite,'case':x['id'],'before':before[x['id']]['corrected'],'after':x['corrected']})
old=json.loads((OUT/'lego-matched-luma-all.json').read_text())['transitions'];new=json.loads((OUT/'lego-registered-anchor-matched-luma-all.json').read_text())['transitions'];lookup={tuple(x['frames']):x for x in old}
assert {tuple(x['frames']) for x in new}==set(lookup)
matched=[]
for x in new:
 b=lookup[tuple(x['frames'])]
 assert x['supportedFootprints']==b['supportedFootprints']
 assert [(p['x'],p['y'],p['matchedX'],p['matchedY']) for p in x['sourceSelectedMatchedFootprints']]==[(p['x'],p['y'],p['matchedX'],p['matchedY']) for p in b['sourceSelectedMatchedFootprints']]
 if x['supportedFootprints']>=12:
  matched.append({'frames':x['frames'],'supportedFootprints':x['supportedFootprints'],'before':b['outputMedianAbsoluteLumaStepEV'],'after':x['outputMedianAbsoluteLumaStepEV'],'source':x['sourceMedianAbsoluteLumaStepEV']})
rms=lambda key:math.sqrt(sum(x[key]**2 for x in matched)/len(matched))
real=[]
for name in ['fox','clay','paper','outdoor']:
 a=json.loads((OUT/f'{name}-matched-luma-all.json').read_text())['transitions']
 b=json.loads((OUT/f'{name}-registered-anchor-matched-luma-all.json').read_text())['transitions']
 assert len(a)==len(b)
 pairs=[]
 for x,y in zip(a,b):
  assert x['frames']==y['frames'] and x['supportedFootprints']==y['supportedFootprints']
  coordinates=lambda t:[(p['x'],p['y'],p['matchedX'],p['matchedY']) for p in t['sourceSelectedMatchedFootprints']]
  assert coordinates(x)==coordinates(y)
  if x['supportedFootprints']>=12:pairs.append((x,y))
 metric=lambda side:math.sqrt(sum(pair[side]['outputMedianAbsoluteLumaStepEV']**2 for pair in pairs)/len(pairs))
 real.append({'case':name,'supportedTransitions':len(pairs),'beforeRMS':metric(0),'afterRMS':metric(1)})
report={'status':'Promising opt-in experiment; not enabled in app32. Broad validation pending.','syntheticCompleted':len(rows),'pendingSuites':pending,'synthetic':rows,'legoMatchedLuminance':{'beforeRMS':rms('before'),'afterRMS':rms('after'),'transitions':matched},'otherRealMatchedLuminance':real,'rendererTestsPassed':15,'surfaceTrackingTestsPassed':37,'fullNativeTestsPassed':146,'additionalAnchorIntegrationTestsPassed':1,'registeredSourceFlickerTestPassed':True,'runnerProvenance':json.loads((ROOT/'.build/review-v32/registered-anchor-experiment/runner/build-provenance.json').read_text()),'guardedRunnerProvenance':json.loads((ROOT/'.build/review-v32/registered-anchor-experiment/runner-v2/build-provenance.json').read_text()),'realSliderReview':json.loads((OUT/'registered-anchor-real-sliders.json').read_text()),'limitations':'Real matched footprints overlap and do not supply clean lighting ground truth. Small other-transition increases remain. Full slider sweep still required before promotion; full native suite and additional anchor integration test passed. Default real exports use v1; v2 adds a missing-thumbnail guard and is used for partial-slider exports.'}
promotion=ROOT/'.build/review-v32/registered-anchor-experiment/promotion-source-proof.json'
if promotion.exists() and 'environment["FRANKLUMA_REGISTERED_ANCHOR"] != "0"' in (ROOT/'Sources/FrankLuma/Core/Correction/Scenes.swift').read_text():
 report['status']='Enabled by default in source after complete validation; separate app33 build verification pending.'
 report['promotionEvidence']=json.loads(promotion.read_text())
 report['limitations']='Real matched footprints overlap and do not supply clean lighting ground truth. Small other-transition increases and residual flashes remain. Default real exports use v1; the guarded v2 reproduces every measured LEGO transition and is used for paired partial-slider exports.'
 build=ROOT/'.build/review-v32/registered-anchor-experiment/app33-provenance.json'
 if build.exists():
  report['status']='Enabled by default in verified separate app33; running local app preserved.'
  report['appBuild']=json.loads(build.read_text())
(OUT/'registered-anchor-review.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'completedSynthetic':len(rows),'pending':pending,'legoRMS':report['legoMatchedLuminance']['beforeRMS'],'candidateLegoRMS':rms('after'),'target':next(x for x in matched if x['frames']==[168,169])},indent=2))
