#!/usr/bin/env python3
"""Fixed-coordinate, source-only photometry diagnostic; never authorizes gains."""
import argparse, collections, hashlib, json, math, statistics
from pathlib import Path


def sample(image, x, y, filtered):
    rgb = image['rgb']; w = image['width']; h = image['height']
    spacing = 2 if filtered else 1
    taps = [(-1, 1), (0, 2), (1, 1)] if filtered else [(0, 1)]
    values = []; supports = []
    for dy in range(-2, 3):
        for dx in range(-2, 3):
            value = [0.0] * 3; support = set()
            for oy, wy in taps:
                for ox, wx in taps:
                    xx = x + spacing * dx + ox; yy = y + spacing * dy + oy
                    if not (0 <= xx < w and 0 <= yy < h): return None
                    p = (yy * w + xx) * 3; v = rgb[p:p+3]
                    if not all(math.isfinite(c) and 0 <= c < .95 for c in v): return None
                    support.add((xx, yy))
                    for c in range(3): value[c] += v[c] * wx * wy / (16 if filtered else 1)
            light = sum(c * weight for c, weight in zip(value, [.2126, .7152, .0722]))
            if light <= .005: return None
            values.append(math.log2(light)); supports.append(support)
    folds = [[p for p in range(25) if p % 5 != 2 and p // 5 < 2],
             [p for p in range(25) if p % 5 != 2 and p // 5 > 2],
             [p for p in range(25) if p // 5 != 2 and p % 5 < 2],
             [p for p in range(25) if p // 5 != 2 and p % 5 > 2]]
    for i in range(4):
        training = set().union(*(supports[p] for p in folds[i]))
        held = set().union(*(supports[p] for p in folds[i ^ 1]))
        if training & held: raise ValueError('Raw source support leaks between held folds')
    return values, folds


def evidence(images, x, y, filtered, alpha):
    samples = [sample(im, x, y, filtered) for im in images]
    if any(s is None for s in samples): return {'rejection': 'invalidObservedSupport'}
    residual = [samples[1][0][p] - (1-alpha)*samples[0][0][p] - alpha*samples[2][0][p] for p in range(25)]
    folds = samples[0][1]; eligible = [p for p in range(25) if p % 5 != 2 and p // 5 != 2]
    coefficient = statistics.median(residual[p] for p in eligible)
    held = 0.0; disagreement = 0.0
    for i, training in enumerate(folds):
        fit = statistics.median(residual[p] for p in training); test = folds[i ^ 1]
        held = max(held, math.sqrt(statistics.mean((residual[p]-fit)**2 for p in test)))
        disagreement = max(disagreement, abs(statistics.median(residual[p] for p in test)-fit))
    interior = math.sqrt(statistics.mean((r-coefficient)**2 for r in residual))
    peak = max(abs(r-coefficient) for r in residual)
    return {'coefficientEV': coefficient, 'heldRMS': held, 'heldDisagreementEV': disagreement,
            'interiorRMS': interior, 'peakInteriorEV': peak,
            'qualifiedAt004EV': max(held, disagreement, interior) <= .04 and peak <= .08}


def main():
    p = argparse.ArgumentParser(); p.add_argument('directory', type=Path); p.add_argument('queries', type=Path)
    p.add_argument('frame', type=int); p.add_argument('output', type=Path); args = p.parse_args()
    if args.output.exists(): raise ValueError('Refusing to overwrite evidence')
    files = [args.directory / f'frame-{i}.json' for i in [args.frame-2, args.frame, args.frame+2]]
    records = [json.loads(f.read_text()) for f in files]; images = [r['image'] for r in records]
    if len({(im['width'], im['height']) for im in images}) != 1: raise ValueError('Geometry mismatch')
    times = [r['time'] for r in records]
    if not times[0] < times[1] < times[2]: raise ValueError('Invalid source timing')
    alpha = (times[1]-times[0])/(times[2]-times[0])
    queries = json.loads(args.queries.read_text()); points = sorted({(r['x'],r['y']) for r in queries if r['sourceFrame'] == args.frame})
    rows = [{'x':x, 'y':y, 'raw':evidence(images,x,y,False,alpha), 'filtered':evidence(images,x,y,True,alpha)} for x,y in points]
    report = {'frame':args.frame, 'times':times, 'alpha':alpha, 'queries':rows,
              'counts':{mode:sum(row[mode].get('qualifiedAt004EV',False) for row in rows) for mode in ['raw','filtered']},
              'limitation':'Fixed coordinates; no flow transport, donor validation, correction authorization or encoded-quality evidence. Filtered and raw footprints have different physical extent. Raw held supports are disjoint for integer sampling only.',
              'sha256':{str(f):hashlib.sha256(f.read_bytes()).hexdigest() for f in files+[args.queries,Path(__file__)]}}
    args.output.write_text(json.dumps(report,indent=2)+'\n'); print(json.dumps(report['counts']))

if __name__ == '__main__': main()
