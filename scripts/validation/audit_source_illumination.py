#!/usr/bin/env python3
"""Source-only spatial agreement prototype on frozen trajectories.

Source thumbnails and track geometry define donors; neither clean frames nor
oracle labels enter estimation. Clean thumbnails and oracle material labels
are used only to score the independently known added illumination. Unknown
means abstain, not zero illumination. No rendered movie is changed.
"""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path
from audit_local_basis import solve


def rgb_mean(image, x, y):
    w = image['width']; rgb = image['rgb']
    return [sum(rgb[((y+dy)*w+x+dx)*3+c] for dy in range(-2,3) for dx in range(-2,3))/25 for c in range(3)]


def level(image, x, y):
    rgb = rgb_mean(image,x,y)
    return math.log2(max(1e-9,sum(a*b for a,b in zip(rgb,[.2126,.7152,.0722]))))


def features(x, y, order):
    return [1,x,y] if order == 1 else [1,x,y,x*x,x*y,y*y]


def fit(points, order):
    n = 3 if order == 1 else 6
    weights = [1.]*len(points)
    for _ in range(5):
        matrix = [[0.]*n for _ in range(n)]; rhs = [0.]*n
        for point,weight in zip(points,weights):
            f = features(point['dx'],point['dy'],order)
            for j in range(n):
                rhs[j] += weight*f[j]*point['change']
                for k in range(n): matrix[j][k] += weight*f[j]*f[k]
        try: coefficients = solve(matrix,rhs)
        except AssertionError: return None
        residuals = [p['change']-predict(coefficients,p,order) for p in points]
        location = statistics.median(residuals)
        scale = max(.001,1.4826*statistics.median(abs(v-location) for v in residuals))
        weights = [min(1,3*scale/max(1e-12,abs(v-location))) for v in residuals]
    return coefficients


def predict(coefficients, point, order):
    return sum(a*b for a,b in zip(coefficients,features(point['dx'],point['dy'],order)))


def independent(a,b):
    return max(abs(a['x']-b['x']),abs(a['y']-b['y'])) >= 5 and max(abs(a['px']-b['px']),abs(a['py']-b['py'])) >= 5


def estimate(query, edge, radius, chroma_limit, agreement, order):
    donors = []
    for p in edge:
        if p['id'] == query['id'] or not independent(p,query): continue
        if math.hypot(p['x']-query['x'],p['y']-query['y']) > radius: continue
        if math.hypot(*(a-b for a,b in zip(p['colour'],query['colour']))) > chroma_limit: continue
        donors.append(dict(p,dx=(p['x']-query['x'])/radius,dy=(p['y']-query['y'])/radius))
    chosen = []
    for p in sorted(donors,key=lambda p:(p['dx']**2+p['dy']**2,p['id'])):
        if all(independent(p,q) for q in chosen): chosen.append(p)
    minimum = 8 if order == 1 else 16
    if len(chosen) < minimum: return None
    # Spatially blocked donors. Each side predicts the other and the held query.
    chosen.sort(key=lambda p:(p['x'],p['y'],p['id']))
    half = len(chosen)//2; subsets = [chosen[:half],chosen[half:]]
    models = [fit(part,order) for part in subsets]
    if any(model is None for model in models): return None
    held = [abs(p['change']-predict(model,p,order)) for model,part in zip(models,reversed(subsets)) for p in part]
    if statistics.median(held) > agreement or max(held) > 2*agreement: return None
    if abs(models[0][0]-models[1][0]) > agreement: return None
    model = fit(chosen,order)
    if model is None: return None
    # Supported absence uses independent observations near the measurement floor.
    quiet = all(abs(p['change']) <= .005 for p in chosen)
    return {'change':0. if quiet else model[0],'state':'quiet' if quiet else 'change',
            'donors':len(chosen),'heldMedianError':statistics.median(held),'heldWorstError':max(held)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('tracks',type=Path); parser.add_argument('source',type=Path)
    parser.add_argument('clean',type=Path); parser.add_argument('output',type=Path)
    parser.add_argument('--radius',type=float,default=18); parser.add_argument('--chroma',type=float,default=.5)
    parser.add_argument('--agreement',type=float,default=.02); parser.add_argument('--order',type=int,choices=[1,2],default=1)
    args = parser.parse_args()
    assert not args.output.exists(), 'Use a new immutable report'
    original = json.loads(args.tracks.read_text())['tracks']
    source = json.loads(args.source.read_text()); clean = json.loads(args.clean.read_text())
    assert len(source)==len(clean)
    edges = {}
    for index,t in enumerate(original):
        mean = rgb_mean(source[t['frames'][0]],t['x'][0],t['y'][0]); r,g,b = [max(.003,v) for v in mean]
        colour = [math.log2(r/g),math.log2(b/g)]
        for j in range(1,len(t['frames'])):
            before,after = t['frames'][j-1:j+1]
            if after != before+1: continue
            point = {'id':index,'frame':after,'x':t['x'][j],'y':t['y'][j],
                'px':t['x'][j-1],'py':t['y'][j-1],'colour':colour,
                'change':t['sourceLevels'][j]-t['sourceLevels'][j-1],
                'group':'crossing' if t['occupancyChanges'] else 'foreground' if t['initialForegroundPixels']==25 else 'background' if t['initialForegroundPixels']==0 else 'mixed'}
            edges.setdefault(after,[]).append(point)
    rows = []
    for frame,points in sorted(edges.items()):
        for p in points:
            result = estimate(p,points,args.radius,args.chroma,args.agreement,args.order)
            # Scoring only: estimator above has no access to clean or mask group.
            truth = (level(source[frame],p['x'],p['y'])-level(clean[frame],p['x'],p['y']))-(level(source[frame-1],p['px'],p['py'])-level(clean[frame-1],p['px'],p['py']))
            rows.append({'track':p['id'],'frame':frame,'group':p['group'],'trueAddedIlluminationStep':truth,'sourceStep':p['change'],'estimate':result})
    summary = {}
    for group in ['all','foreground','background','mixed','crossing']:
        subset = [p for p in rows if group=='all' or p['group']==group]
        known = [p for p in subset if p['estimate'] is not None]
        errors = [p['estimate']['change']-p['trueAddedIlluminationStep'] for p in known]
        source_errors = [p['sourceStep']-p['trueAddedIlluminationStep'] for p in known]
        summary[group] = {'observations':len(subset),'supported':len(known),'supportedQuiet':sum(p['estimate']['state']=='quiet' for p in known),
            'supportedErrorRMS':math.sqrt(sum(v*v for v in errors)/len(errors)) if errors else None,
            'individualSourceStepErrorRMS':math.sqrt(sum(v*v for v in source_errors)/len(source_errors)) if source_errors else None,
            'worstSupportedError':max(map(abs,errors),default=None)}
    report = {'scope':'Source-only held-spatial illumination-step prototype; no rendering or temporal integration; unknown must abstain',
        'parameters':{'radius':args.radius,'chroma':args.chroma,'agreement':args.agreement,'order':args.order},
        'inputs':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [args.tracks,args.source,args.clean]},'summary':summary,'rows':rows}
    args.output.parent.mkdir(parents=True,exist_ok=True);args.output.write_text(json.dumps(report,indent=2));print(json.dumps(summary))


if __name__=='__main__': main()
