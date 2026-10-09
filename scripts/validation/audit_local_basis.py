#!/usr/bin/env python3
"""Fit independent coefficients through a fixed source-selected spatial basis.

Offline full-strength, stationary-interval diagnostic. Holds out entire sampling
rows from photometric fitting; their source geometry may still define the basis.
"""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path
from audit_persistent_support import descriptor


def solve(matrix, rhs):
    a = [row[:] + [value] for row,value in zip(matrix,rhs)]
    n = len(rhs)
    for i in range(n):
        pivot = max(range(i,n),key=lambda j:abs(a[j][i]))
        a[i],a[pivot] = a[pivot],a[i]
        assert abs(a[i][i]) > 1e-12
        for j in range(i+1,n):
            factor = a[j][i]/a[i][i]
            for k in range(i,n+1):
                a[j][k] -= factor*a[i][k]
    x = [0.0]*n
    for i in reversed(range(n)):
        x[i] = (a[i][-1]-sum(a[i][j]*x[j] for j in range(i+1,n)))/a[i][i]
    return x


def response(sample, coefficients):
    total = 0.0
    derivative = [0.0]*len(coefficients)
    for light,weights in sample['pixels']:
        value = light*2**sum(coefficients[j]*weight for j,weight in weights)
        total += value
        for j,weight in weights:
            derivative[j] += value*weight
    derivative = [v/total for v in derivative]
    before = sample['beforeSum']
    if 'beforePixels' in sample:
        before = 0.0
        previous_derivative = [0.0]*len(coefficients)
        for light,weights in sample['beforePixels']:
            value = light*2**sum(coefficients[j]*weight for j,weight in weights)
            before += value
            for j,weight in weights:
                previous_derivative[j] += value*weight
        derivative = [a-b/before for a,b in zip(derivative,previous_derivative)]
    return math.log2(total/before)-sample.get('target',0), derivative


def fit(samples, training, count, ridge, limit=.25):
    coefficients = [0.0]*count
    for _ in range(5):
        matrix = [[ridge if i == j else 0.0 for j in range(count)] for i in range(count)]
        rhs = [-ridge*c for c in coefficients]
        for i in training:
            error,jacobian = response(samples[i],coefficients)
            supported = [(j,d) for j,d in enumerate(jacobian) if abs(d)>1e-12]
            for j,dj in supported:
                rhs[j] -= dj*error
                for k,dk in supported:
                    matrix[j][k] += dj*dk
        delta = solve(matrix,rhs)
        coefficients = [max(-limit,min(limit,c+d)) for c,d in zip(coefficients,delta)]
    return coefficients


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--matches',type=Path,required=True)
    p.add_argument('--source-thumbnails',type=Path,required=True)
    p.add_argument('--corrected-thumbnails',type=Path,required=True)
    p.add_argument('--start',type=int,required=True)
    p.add_argument('--end',type=int,required=True)
    p.add_argument('--event',type=int,required=True)
    p.add_argument('--ridge',type=float,default=.05)
    p.add_argument('--appearance',type=float,default=0,
                   help='Fixed source chroma gating width in stops; zero disables')
    p.add_argument('--strength',type=float,default=1)
    p.add_argument('--trend',type=float,default=0,help='Intentional source step in EV')
    p.add_argument('--foreground-rle',type=Path)
    p.add_argument('--temporal',action='store_true',help='Fit all interval edges; constrain endpoint gains to zero')
    p.add_argument('--mask-width',type=int,default=320)
    p.add_argument('--mask-height',type=int,default=192)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--native-problem',type=Path,help='Write frozen input for the Swift solver parity audit')
    args = p.parse_args()
    assert args.ridge > 0
    assert args.appearance >= 0
    assert 0 <= args.strength <= 1
    source = json.loads(args.source_thumbnails.read_text())
    corrected = json.loads(args.corrected_thumbnails.read_text())
    matches = json.loads(args.matches.read_text())['transitions']
    assert len(source) == len(corrected)
    assert 0 <= args.start < args.event <= args.end < len(source)
    selected = [t for t in matches if args.start <= t['frames'][0] < args.end]
    assert [t['frames'] for t in selected] == [[i,i+1] for i in range(args.start,args.end)]
    common = None
    for t in selected:
        points = {(m['x'],m['y']) for m in t['sourceSelectedMatchedFootprints']
                  if (m['x'],m['y']) == (m['matchedX'],m['matchedY'])}
        common = points if common is None else common & points
    points = []
    for x,y in sorted(common):
        anchor = descriptor(source[args.start],x,y,'log-plane')
        if anchor and all((d := descriptor(source[i],x,y,'log-plane')) and
                          sum(a*b for a,b in zip(anchor,d)) > .95
                          for i in range(args.start+1,args.end+1)):
            points.append((int(x),int(y)))
    w,h = source[0]['width'],source[0]['height']
    basis = [[] for _ in range(w*h)]
    reference = source[args.start]
    def chroma(pixel):
        rgb = [max(.003,reference['rgb'][pixel*3+c]) for c in range(3)]
        return [math.log2(rgb[0]/rgb[1]),math.log2(rgb[2]/rgb[1])]
    for j,(x,y) in enumerate(points):
        centre = chroma(y*w+x)
        for dy in range(-6,7):
            for dx in range(-6,7):
                weight = (1-abs(dx)/7)*(1-abs(dy)/7)
                if args.appearance:
                    colour = chroma((y+dy)*w+x+dx)
                    weight *= math.exp(-sum((a-b)**2 for a,b in zip(colour,centre))/args.appearance**2)
                if weight > 1e-12:
                    basis[(y+dy)*w+x+dx].append((j,weight))
    # Same gain for identical coefficients irrespective of anchor density.
    for pixel,weights in enumerate(basis):
        if weights:
            scale = max(v for _,v in weights)/sum(v for _,v in weights)
            basis[pixel] = [(j,v*scale) for j,v in weights]
    def light(image,pixel):
        return sum(image['rgb'][pixel*3+c]*v for c,v in enumerate([.2126,.7152,.0722]))
    samples = []
    edges = range(args.start+1,args.end+1) if args.temporal else [args.event]
    def weights(frame,pixel):
        if not args.temporal:
            return basis[pixel]
        if frame in [args.start,args.end]:
            return []
        return [((frame-args.start-1)*len(points)+j,v) for j,v in basis[pixel]]
    for frame in edges:
      before,after = corrected[frame-1],corrected[frame]
      for point,(x,y) in enumerate(points):
        pixels = [(y+dy)*w+x+dx for dy in range(-6,7) for dx in range(-6,7)]
        sample = {'point':point,'frame':frame,
                        'beforeSum':sum(light(before,pixel) for pixel in pixels),
                        'pixels':[(light(after,pixel),weights(frame,pixel)) for pixel in pixels],
                        'target':(1-args.strength)*math.log2(
                            sum(light(source[frame],pixel) for pixel in pixels)/
                            sum(light(source[frame-1],pixel) for pixel in pixels))
                            +args.strength*args.trend}
        if args.temporal:
            sample['beforePixels'] = [(light(before,pixel),weights(frame-1,pixel)) for pixel in pixels]
        samples.append(sample)
    coefficient_count = len(points)*(args.end-args.start-1) if args.temporal else len(points)
    zero = [0.0]*coefficient_count
    baseline = [response(s,zero)[0] for s in samples]
    folds = []
    for row in sorted({y for _,y in points}):
        training = [i for i,s in enumerate(samples) if points[s['point']][1] != row]
        held = [i for i,s in enumerate(samples) if points[s['point']][1] == row]
        if len(held) < 3 or len(training) < 6:
            continue
        coefficients = fit(samples,training,coefficient_count,args.ridge,.25*args.strength)
        errors = [response(s,coefficients)[0] for s in samples]
        folds.append({'heldRow':row,'heldCount':len(held),'trainingCount':len(training),
                      'heldRMSBefore':math.sqrt(statistics.mean(baseline[i]**2 for i in held)),
                      'heldRMSAfter':math.sqrt(statistics.mean(errors[i]**2 for i in held)),
                      'worstHeldAbsoluteResidualIncrease':max(abs(errors[i])-abs(baseline[i]) for i in held)})
    coefficients = fit(samples,list(range(len(samples))),coefficient_count,args.ridge,.25*args.strength) if points else []
    errors = [response(s,coefficients)[0] for s in samples]
    foreground = []
    if args.foreground_rle:
        masks = json.loads(args.foreground_rle.read_text())
        for frame in range(args.start,args.end+1):
            gain_field = [sum(coefficients[j]*weight for j,weight in weights(frame,pixel)) for pixel in range(w*h)]
            mask = []
            for run,count in enumerate(masks[frame]):
                mask.extend([run%2 == 1]*count)
            assert len(mask) == args.mask_width*args.mask_height
            pixels = [y*w+x for y in range(h) for x in range(w)
                      if mask[min(args.mask_height-1,int((y+.5)/h*args.mask_height))*args.mask_width
                              +min(args.mask_width-1,int((x+.5)/w*args.mask_width))]]
            gains = [gain_field[pixel] if args.temporal or frame >= args.event else 0 for pixel in pixels]
            foreground.append({'frame':frame,'foregroundThumbnailPixels':len(pixels),
                               'nonzeroCorrectionPixels':sum(abs(v)>1e-12 for v in gains),
                               'maximumAbsoluteGainEV':max(map(abs,gains),default=0)})
    result = {'interval':[args.start,args.end],'event':args.event,'ridge':args.ridge,
              'appearanceWidthEV':args.appearance,
              'strength':args.strength,'trendEV':args.trend,
              'temporal':args.temporal,'temporalEndpointGainsZero':args.temporal,
              'points':points,'coefficientsEV':coefficients,'folds':folds,
              'foregroundDiagnostic':foreground,
              'allFitRMSBefore':math.sqrt(statistics.mean(v*v for v in baseline)) if points else None,
              'allFitRMSAfter':math.sqrt(statistics.mean(v*v for v in errors)) if points else None,
              'allFitWorstAbsoluteResidualIncrease':max((abs(a)-abs(b) for a,b in zip(errors,baseline)),default=None),
              'inputs':{str(path.resolve()):hashlib.sha256(path.read_bytes()).hexdigest() for path in
                        [args.matches,args.source_thumbnails,args.corrected_thumbnails]},
              'limitations':['Explicit stationary interval and full-strength zero-step target.',
                             'Training fit is not independent evidence; footprints overlap.',
                             'Held rows retain source-selected basis geometry but no output fitting data.',
                             'No export, quiet-edge, brightness, slider or perceptual validation.']}
    if args.foreground_rle:
        result['inputs'][str(args.foreground_rle.resolve())] = hashlib.sha256(args.foreground_rle.read_bytes()).hexdigest()
        result['foregroundMaskDimensions'] = [args.mask_width,args.mask_height]
    if args.native_problem:
        def pixels(values):
            return [{'light':light,'weights':[{'index':j,'value':v} for j,v in weights]}
                    for light,weights in values]
        problem = {'count':coefficient_count,'ridge':args.ridge,'limit':.25*args.strength,
                   'samples':[{'before':pixels(s.get('beforePixels',[(s['beforeSum'],[])])),
                               'after':pixels(s['pixels']),'target':s['target']} for s in samples],
                   'expectedCoefficients':coefficients,'expectedRMS':result['allFitRMSAfter']}
        with args.native_problem.open('x') as f:
            json.dump(problem,f);f.write('\n')
    with args.output.open('x') as f:
        json.dump(result,f,indent=2);f.write('\n')


if __name__ == '__main__':
    main()
