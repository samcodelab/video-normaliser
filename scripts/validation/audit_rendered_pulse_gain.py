#!/usr/bin/env python3
"""Source-selected composed-gain diagnostic; never uses a clean target to choose correction."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import statistics


def main():
    p = argparse.ArgumentParser()
    p.add_argument('source',type=Path)
    p.add_argument('corrected',type=Path)
    p.add_argument('pulse_log',type=Path)
    p.add_argument('frame',type=int)
    p.add_argument('output',type=Path)
    p.add_argument('--include-unknown',action='store_true',help='Inspect all held source queries; unknown clocks do not authorize correction')
    args = p.parse_args()
    if args.output.exists():raise ValueError('Refusing to overwrite evidence')
    input_files=[]
    def decode(path):
        if path.is_dir():
            files=sorted(path.glob('frame-*.json'))
            records=[json.loads(p.read_text()) for p in files]
            if not records or len({r['index'] for r in records}) != len(records):raise ValueError('Missing or duplicate frames')
            input_files.extend(files)
            return {r['index']:r['image'] for r in records},{r['index']:r['time'] for r in records}
        input_files.append(path)
        return dict(enumerate(json.loads(path.read_text()))),{}
    source,source_times=decode(args.source);corrected,corrected_times=decode(args.corrected)
    if set(source) != set(corrected) or args.frame not in source:raise ValueError('Invalid frame indices')
    if source_times or corrected_times:
        if set(source_times) != set(corrected_times) or any(abs(source_times[i]-corrected_times[i])>1e-6 for i in source_times):raise ValueError('Presentation timing mismatch')
    records=[];frame=None;times=None;indices=None
    for line in args.pulse_log.read_text().splitlines():
        if line.startswith('SOURCE_DETAIL_FRAME '):
            info=json.loads(line.split(' ',1)[1]);frame=info['frame']
            if frame==args.frame:
                evidence=info.get('cameraEvidence',{})
                if not evidence.get('geometrySupported') or any(evidence.get('movingModels',[True,True])):
                    raise ValueError('This audit requires corroborated stationary camera geometry')
                times=[info['beforeTime'],info['time'],info['afterTime']]
                indices=[info['beforeFrame'],info['frame'],info['afterFrame']]
        elif line.startswith('COMMON_LIGHT_SOURCE_PULSE ') and frame==args.frame:
            evidence=json.loads(line.split(' ',1)[1])
            if evidence.get('refinedSampling'):raise ValueError('This integer-position audit does not support refined sample coordinates')
            records.extend(evidence.get('queryPoints',[]) if args.include_unknown else evidence['eventPoints'])
    if not records or times is None or indices is None:raise ValueError('Missing source evidence')
    if any(i not in source for i in indices):raise ValueError('Missing source interval endpoints')
    alpha=(times[1]-times[0])/(times[2]-times[0])
    def patch(image,x,y,require_unclipped=True):
        w,h=image['width'],image['height']
        if x<2 or y<2 or x+2>=w or y+2>=h:return None
        values=[]
        for dy in range(-2,3):
            for dx in range(-2,3):
                i=((y+dy)*w+x+dx)*3;rgb=image['rgb'][i:i+3]
                if not all(math.isfinite(v) and v>=0 and (not require_unclipped or v<.95) for v in rgb):return None
                yvalue=sum(a*b for a,b in zip(rgb,[.2126,.7152,.0722]))
                if yvalue<=.005:return None
                values.append(yvalue)
        return math.log2(statistics.mean(values))
    def curvature(v):return v[1]-(1-alpha)*v[0]-alpha*v[2]
    rows=[]
    for r in records:
        a=[];b=[]
        for i in indices:
            if (source[i]['width'],source[i]['height']) != (corrected[i]['width'],corrected[i]['height']):raise ValueError('Geometry mismatch')
            a.append(patch(source[i],r['x'],r['y']));b.append(patch(corrected[i],r['x'],r['y'],require_unclipped=False))
        if any(v is None for v in a+b):continue
        gain=[y-x for x,y in zip(a,b)]
        rows.append({'x':r['x'],'y':r['y'],'sourceCurvatureEV':curvature(a),
                     'outputCurvatureEV':curvature(b),'automaticGainCurvatureEV':curvature(gain),
                     'heldSourceExcursionEV':r['excursion'],'heldSourceErrorEV':r.get('heldError',0),
                     'clockState':r.get('clockState',r.get('state','unknown')),'donorClockEV':r.get('donorEvent'),
                     'additionalCurvatureForFullRemovalEV':-r['excursion']-curvature(gain)})
    if not rows:raise ValueError('No valid rendered comparisons')
    def stats(values):return {'count':len(values),'median':statistics.median(values),'rms':math.sqrt(statistics.mean(v*v for v in values)),'minimum':min(values),'maximum':max(values)}
    report={'frame':args.frame,'frameIndices':indices,'alpha':alpha,'footprints':rows,
            'statistics':{key:stats([r[key] for r in rows if isinstance(r[key],(int,float))]) for key in rows[0]
                          if key not in ['x','y','clockState'] and any(isinstance(r[key],(int,float)) for r in rows)},
            'limitation':'Source-selected camera-stationary queries; full-removal curvature is diagnostic, not an authorized gain, spatial model or export.',
            'hashes':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in input_files+[args.pulse_log,Path(__file__)]}}
    args.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report['statistics'],indent=2))

if __name__=='__main__':main()
