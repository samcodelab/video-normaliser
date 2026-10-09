#!/usr/bin/env python3
"""Offline stationary episode basis probe; never modifies media or app settings.

Fits through actual patch-mean response to a source-selected fixed pixel basis.
The explicit interval is a diagnostic selection, not an automatic scene model.
"""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path
from audit_persistent_support import descriptor


def mean(image, x, y, basis=None, gain=0):
    total = 0
    for dy in range(-6, 7):
        for dx in range(-6, 7):
            pixel = (y+dy)*image['width']+x+dx
            total += sum(image['rgb'][pixel*3+c]*weight for c, weight in enumerate([.2126,.7152,.0722]))*2**(gain*basis[pixel] if basis else 0)
    return total/169


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--matches', type=Path, required=True)
    p.add_argument('--source-thumbnails', type=Path, required=True)
    p.add_argument('--corrected-thumbnails', type=Path, required=True)
    p.add_argument('--start', type=int, required=True)
    p.add_argument('--end', type=int, required=True, help='Inclusive final frame')
    p.add_argument('--event', type=int, required=True, help='First post-event frame')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--grouping', choices=['material','all'], default='material')
    args = p.parse_args()
    source = json.loads(args.source_thumbnails.read_text())
    corrected = json.loads(args.corrected_thumbnails.read_text())
    matches = json.loads(args.matches.read_text())['transitions']
    assert len(source) == len(corrected)
    assert 0 <= args.start < args.event <= args.end < len(source)
    w, h = source[0]['width'], source[0]['height']
    selected = [t for t in matches if args.start <= t['frames'][0] < args.end]
    assert [t['frames'] for t in selected] == [[i,i+1] for i in range(args.start,args.end)]
    common = None
    for t in selected:
        points = {(m['x'],m['y']) for m in t['sourceSelectedMatchedFootprints']
                  if m['x'] == m['matchedX'] and m['y'] == m['matchedY']}
        common = points if common is None else common & points
    stable = []
    for x,y in sorted(common):
        anchor = descriptor(source[args.start], x,y,'log-plane')
        if anchor and all((d := descriptor(source[i],x,y,'log-plane')) and
                          sum(a*b for a,b in zip(anchor,d)) > .95
                          for i in range(args.start+1,args.end+1)):
            stable.append((int(x),int(y)))
    # Partition material using source only, independent of rendered residual.
    groups = {}
    for x,y in stable:
        rgb = [statistics.mean(source[args.event-1]['rgb'][((y+dy)*w+x+dx)*3+c]
                               for dy in range(-6,7) for dx in range(-6,7)) for c in range(3)]
        key = (math.floor(math.log2(max(.003,rgb[0])/max(.003,rgb[1]))),
               math.floor(math.log2(max(.003,rgb[2])/max(.003,rgb[1]))))
        groups.setdefault(key,[]).append((x,y))
    if args.grouping == 'all':
        groups = {('all',):stable}
    results = []
    for key,points in sorted(groups.items()):
        if len(points) < 6:
            continue
        basis = [0.0]*(w*h)
        for x,y in points:
            for dy in range(-6,7):
                for dx in range(-6,7):
                    # Fixed source footprint union; density does not scale gain.
                    weight = max(0,1-abs(dx)/7)*max(0,1-abs(dy)/7)
                    pixel = (y+dy)*w+x+dx
                    basis[pixel] = max(basis[pixel],weight)
        before,after = corrected[args.event-1],corrected[args.event]
        steps = {pt:math.log2(mean(after,*pt)/mean(before,*pt)) for pt in points}
        folds = []
        for right in [False,True]:
            train = [pt for pt in points if (pt[0] >= w/2) == right]
            held = [pt for pt in points if (pt[0] >= w/2) != right]
            if len(train) < 3 or len(held) < 3:
                continue
            def error(pt,gain):
                return math.log2(mean(after,*pt,basis=basis,gain=gain)/mean(before,*pt))
            gain = min((i/200 for i in range(-50,51)),
                       key=lambda g:statistics.mean(error(pt,g)**2 for pt in train))
            folds.append({'trainingRight':right,'trainingCount':len(train),'heldCount':len(held),
                          'coefficientEV':gain,
                          'heldRMSBefore':math.sqrt(statistics.mean(steps[pt]**2 for pt in held)),
                          'heldRMSAfter':math.sqrt(statistics.mean(error(pt,gain)**2 for pt in held)),
                          'worstHeldAbsoluteResidualIncrease':max(abs(error(pt,gain))-abs(steps[pt]) for pt in held)})
        temporal = []
        if folds:
            coefficient = statistics.mean(fold['coefficientEV'] for fold in folds)
            for t in selected:
                a,b = t['frames']
                ga = coefficient if a >= args.event else 0
                gb = coefficient if b >= args.event else 0
                baseline, candidate = [], []
                for match in t['sourceSelectedMatchedFootprints']:
                    x,y = match['x'],match['y']
                    if (x,y) != (match['matchedX'],match['matchedY']):
                        continue
                    baseline.append(math.log2(mean(corrected[b],x,y)/mean(corrected[a],x,y)))
                    candidate.append(math.log2(mean(corrected[b],x,y,basis,gb)/mean(corrected[a],x,y,basis,ga)))
                temporal.append({'frames':[a,b],'allStationaryMatches':len(baseline),
                                 'medianAbsoluteBefore':statistics.median(abs(v) for v in baseline),
                                 'medianAbsoluteAfter':statistics.median(abs(v) for v in candidate)})
        results.append({'sourceMaterialBin':key,'tracks':len(points),
                        'nonzeroBasisPixels':sum(v>0 for v in basis),'folds':folds,
                        'temporalCheck':temporal})
    result = {'interval':[args.start,args.end],'event':args.event,'stableTracks':len(stable),
              'grouping':args.grouping,
              'groups':results,
              'inputs':{str(path.resolve()):hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in [args.matches,args.source_thumbnails,args.corrected_thumbnails]},
              'limitations':['Explicit stationary interval; not automatic tracking or an export.',
                             'Target is zero step at full correction; intentional lighting must be handled separately.',
                             'Source footprints overlap; samples are not statistically independent.',
                             'No quiet-edge, boundary, full-resolution or encoded validation yet.']}
    with args.output.open('x') as f:
        json.dump(result,f,indent=2);f.write('\n')


if __name__ == '__main__':
    main()
