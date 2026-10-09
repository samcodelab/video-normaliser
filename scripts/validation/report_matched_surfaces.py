"""Summarise supported encoded transitions, keeping missing coverage explicit."""
import argparse
import json
import math
from pathlib import Path
from statistics import median

ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'dist/Benchmarks/general-review-v30'

def collect():
    results=[]
    for name in ['lego','fox','clay','paper','outdoor']:
        p=OUT/f'{name}-matched-surface-all.json'
        if not p.exists():
            results.append({'case':name,'status':'pending'})
            continue
        data=json.loads(p.read_text())
        supported=[x for x in data['transitions'] if x['supportedFootprints'] >= 12]
        source=[x['sourceMedianAbsoluteStepEV'] for x in supported]
        output=[x['outputMedianAbsoluteStepEV'] for x in supported]
        results.append({'case':name,'status':'measured' if supported else 'unsupported',
                        'withinSourceSceneTransitions':len(data['transitions']),
                        'supportedTransitions':len(supported),
                        'medianSourceAbsoluteStepEV':median(source) if source else None,
                        'medianOutputAbsoluteStepEV':median(output) if output else None,
                        'rmsOfMedianSourceAbsoluteStepsEV':math.sqrt(sum(x*x for x in source)/len(source)) if source else None,
                        'rmsOfMedianOutputAbsoluteStepsEV':math.sqrt(sum(x*x for x in output)/len(output)) if output else None,
                        'largestSupportedOutputTransitions':sorted([
                            {key:x[key] for key in ['frames','supportedFootprints','sourceMedianAbsoluteStepEV','outputMedianAbsoluteStepEV','cameraModelFound']}
                            for x in supported],key=lambda x:x['outputMedianAbsoluteStepEV'],reverse=True)[:12]})
    return {'cases':results,'method':'Within-scene, source-selected 13x13 texture footprints; camera model or matching fixed geometry; correlation >0.95, texture energy >0.03; at least 12 footprints for a supported transition.',
            'limitations':'Mean channel log-EV changes include intentional illumination and residual reflectance/registration changes. Footprints overlap. No verified clean reference or perceptual invisibility claim. Missing measurements are never zero error.',
            'nativeProvenance':json.loads((ROOT/'.build/matched-surface-audit/provenance.json').read_text())}

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--progress',action='store_true');args=parser.parse_args()
    result=collect()
    if not args.progress:
        assert all(x['status']!='pending' for x in result['cases'])
    (OUT/'matched-surface-review.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result['cases'],indent=2))
