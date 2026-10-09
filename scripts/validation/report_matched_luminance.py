"""Summarise immutable source-selected matched linear-luminance measurements."""
import argparse
import html
import json
import math
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'dist/Benchmarks/general-review-v30'


def collect(progress):
    expected=json.loads((ROOT/'.build/review-v32/matched-luma-runner/provenance.json').read_text())
    cases=[]
    for name in ['lego','fox','clay','paper','outdoor']:
        p=OUT/f'{name}-matched-luma-all.json'
        if not p.exists():
            cases.append({'case':name,'status':'pending'})
            continue
        a=json.loads(p.read_text())
        if 'nativeProvenance' not in a:
            cases.append({'case':name,'status':'pending'})
            continue
        assert a['nativeProvenance']==expected
        supported=[x for x in a['transitions'] if x['supportedFootprints']>=12]
        def rms(key):
            return math.sqrt(sum(x[key]**2 for x in supported)/len(supported)) if supported else None
        before=rms('sourceMedianAbsoluteLumaStepEV');after=rms('outputMedianAbsoluteLumaStepEV')
        cases.append({'case':name,'status':'measured' if supported else 'unsupported',
                      'withinSourceSceneTransitions':len(a['transitions']),'supportedTransitions':len(supported),
                      'sourceRMSOfMedianAbsoluteLumaStepsEV':before,'outputRMSOfMedianAbsoluteLumaStepsEV':after,
                      'relativeReduction':1-after/before if before else None,
                      'largestResiduals':sorted([{key:x[key] for key in ['frames','supportedFootprints','cameraModelFound','sourceMedianAbsoluteLumaStepEV','outputMedianAbsoluteLumaStepEV']} for x in supported],key=lambda x:x['outputMedianAbsoluteLumaStepEV'],reverse=True)[:12],
                      'rights':a['rights'],'sourceSha256':a['sourceSha256'],'correctedSha256':a['correctedSha256']})
    if not progress: assert all(x['status']!='pending' for x in cases)
    return {'cases':cases,'nativeProvenance':expected,
            'method':'Actual encoded linear luminance on source-selected matched 13x13 footprints, source texture correlation >0.95, source cuts excluded, at least 12 supported footprints per measured transition. Summarised as RMS of transition median absolute EV changes.',
            'limitations':'Footprints overlap and cover only supported texture. Intentional lighting, occlusion, deformation and registration errors can contribute. No clean target or perceptual invisibility guarantee. Reduction compares current correction with source, not with the previous algorithm.'}


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--progress',action='store_true');args=parser.parse_args()
    report=collect(args.progress)
    (OUT/'matched-luminance-review.json').write_text(json.dumps(report,indent=2)+'\n')
    rows=[]
    for c in report['cases']:
        if c['status']!='measured':
            rows.append(f"<tr><td>{c['case']}</td><td colspan='4'>{c['status']}</td></tr>")
            continue
        rows.append(f"<tr><td>{c['case']}</td><td>{c['supportedTransitions']}/{c['withinSourceSceneTransitions']}</td><td>{c['sourceRMSOfMedianAbsoluteLumaStepsEV']:.5f}</td><td>{c['outputRMSOfMedianAbsoluteLumaStepsEV']:.5f}</td><td>{c['relativeReduction']:.1%}</td></tr>")
    text='''<!doctype html><meta charset="utf-8"><title>Matched luminance review</title><style>body{font:16px system-ui;max-width:1000px;margin:40px auto;padding:0 20px}td,th{padding:9px;border-bottom:1px solid #ccc}</style><h1>Matched luminance review</h1>'''
    text+=f"<p>{html.escape(report['method'])}</p><table><tr><th>Video</th><th>Supported transitions</th><th>Source EV</th><th>Corrected EV</th><th>Reduction</th></tr>{''.join(rows)}</table><p>{html.escape(report['limitations'])}</p><p><a href='matched-luminance-review.json'>Residual transitions, rights and provenance</a></p>"
    (OUT/'matched-luminance-review.html').write_text(text)
    print(json.dumps([{k:v for k,v in c.items() if k not in ['largestResiduals','rights','sourceSha256','correctedSha256']} for c in report['cases']],indent=2))
