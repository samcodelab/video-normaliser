#!/usr/bin/env python3
"""Compare source-only pulse evidence with an independently encoded clean target."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('target', type=Path)
    parser.add_argument('pulse_log', type=Path)
    parser.add_argument('frame', type=int)
    parser.add_argument('output', type=Path)
    parser.add_argument('--corrected', type=Path)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError('Refusing to overwrite evidence')
    source, target = [json.loads(p.read_text()) for p in [args.source, args.target]]
    if len(source) != len(target) or not 0 < args.frame < len(source)-1:
        raise ValueError('Frame count or bracket mismatch')
    for a,b in zip(source,target):
        if (a['width'],a['height']) != (b['width'],b['height']):
            raise ValueError('Geometry mismatch')
    corrected = json.loads(args.corrected.read_text()) if args.corrected else None
    if corrected is not None and (len(corrected) != len(source) or any((a['width'],a['height']) != (b['width'],b['height']) for a,b in zip(source,corrected))):
        raise ValueError('Corrected geometry or frame count mismatch')
    points = {}
    current = None
    for line in args.pulse_log.read_text().splitlines():
        if line.startswith('SOURCE_DETAIL_FRAME '):
            info = json.loads(line.split(' ',1)[1]);current = info['frame']
            if current == args.frame:
                evidence=info.get('cameraEvidence',{})
                alpha=(info['time']-info['beforeTime'])/(info['afterTime']-info['beforeTime'])
                if not evidence.get('geometrySupported') or any(evidence.get('movingModels',[True,True])) or abs(alpha-.5)>1e-6:
                    raise ValueError('This audit requires stationary camera and equal bracket timing')
        elif line.startswith('COMMON_LIGHT_SOURCE_PULSE ') and current == args.frame:
            row = json.loads(line.split(' ',1)[1])
            if row.get('refinedSampling'):raise ValueError('This integer-position audit does not support refined sample coordinates')
            for p in row['eventPoints']:
                points[(p['x'],p['y'])] = p
    if not points:
        raise ValueError('No source-selected event queries at requested frame')

    def luminance(image,pixel):
        rgb = image['rgb'][pixel*3:pixel*3+3]
        if len(rgb) != 3 or not all(math.isfinite(v) and 0 <= v < .95 for v in rgb):
            return None
        y = sum(v*w for v,w in zip(rgb,[.2126,.7152,.0722]))
        return y if y > .005 else None

    def patch(image,x,y):
        if x < 2 or y < 2 or x+2 >= image['width'] or y+2 >= image['height']:
            return None
        values = [luminance(image,(y+dy)*image['width']+x+dx)
                  for dy in range(-2,3) for dx in range(-2,3)]
        return statistics.mean(values) if all(v is not None for v in values) else None

    selected = []
    for (x,y),point in points.items():
        a = [patch(source[i],x,y) for i in range(args.frame-1,args.frame+2)]
        b = [patch(target[i],x,y) for i in range(args.frame-1,args.frame+2)]
        if any(v is None for v in a+b):
            continue
        d = [patch(corrected[i],x,y) for i in range(args.frame-1,args.frame+2)] if corrected is not None else None
        if d is not None and any(v is None for v in d):
            continue
        selected.append({'x':x,'y':y,'sameFrameSourceToTargetEV':math.log2(a[1]/b[1]),
                         'sourceCurvatureEV':math.log2(a[1])-.5*(math.log2(a[0])+math.log2(a[2])),
                         'targetCurvatureEV':math.log2(b[1])-.5*(math.log2(b[0])+math.log2(b[2])),
                         'donorClockEV':point['donorEvent']})
        if d is not None:
            gain = [math.log2(v/u) for v,u in zip(d,a)]
            residual = [math.log2(v/u) for v,u in zip(d,b)]
            selected[-1].update(automaticGainEV=gain[1],automaticGainCurvatureEV=gain[1]-.5*(gain[0]+gain[2]),correctedToTargetEV=residual[1],correctedToTargetCurvatureEV=residual[1]-.5*(residual[0]+residual[2]))
    if not selected:
        raise ValueError('No valid target comparisons')
    gains = []
    for p in range(source[args.frame]['width']*source[args.frame]['height']):
        a,b = luminance(source[args.frame],p),luminance(target[args.frame],p)
        if a is not None and b is not None:
            gains.append(math.log2(a/b))
    def describe(values):
        return {'count':len(values),'median':statistics.median(values),
                'rms':math.sqrt(statistics.mean(v*v for v in values)),
                'minimum':min(values),'maximum':max(values)}
    report = {'frame':args.frame,'frames':len(source),
              'allValidSameFrameGainEV':describe(gains),
              'selectedSameFrameGainEV':describe([r['sameFrameSourceToTargetEV'] for r in selected]),
              'selectedTargetCurvatureEV':describe([r['targetCurvatureEV'] for r in selected]),
              'selectedSourceCurvatureEV':describe([r['sourceCurvatureEV'] for r in selected]),
              'selectedDonorClockEV':describe([r['donorClockEV'] for r in selected]),
              'footprints':selected,
              'limitation':'Integer camera-stationary footprint analysis; not a corrected export or arbitrary VFR curvature audit.',
              'hashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest()
                        for p in [args.source,args.target,args.pulse_log,Path(__file__)]}}
    if corrected is not None:
        for key in ['automaticGainEV','automaticGainCurvatureEV','correctedToTargetEV','correctedToTargetCurvatureEV']:
            report[key] = describe([r[key] for r in selected])
        report['hashes'][str(args.corrected)] = hashlib.sha256(args.corrected.read_bytes()).hexdigest()
    args.output.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ['footprints','hashes']},indent=2))

if __name__ == '__main__':
    main()
