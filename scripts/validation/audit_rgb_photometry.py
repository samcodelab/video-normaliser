"""Compare positive gain-only and gain+offset models at frozen source matches.
This is an analysis diagnostic; it never changes correction or renders pixels.
"""
import argparse
import json
import math
import statistics
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('thumbnails', type=Path)
parser.add_argument('tracking', type=Path)
parser.add_argument('output', type=Path)
parser.add_argument('--first-frame', type=int, required=True)
parser.add_argument('--fold', choices=['checkerboard','vertical-block'], default='checkerboard')
parser.add_argument('--all-tracks', action='store_true', help='Audit every retained adjacent track edge, rather than luminance fallback edges only.')
args = parser.parse_args()
fold = lambda dx,dy: (dx+dy)%2 if args.fold == 'checkerboard' else int(dx >= 0)
assert not args.output.exists(), args.output
images = json.loads(args.thumbnails.read_text())
tracking = json.loads(args.tracking.read_text())

def sample(image, x, y, channel):
    w, h = image['width'], image['height']
    if not (0 <= x < w-1 and 0 <= y < h-1):
        return None
    ix, iy = int(x), int(y)
    fx, fy = x-ix, y-iy
    p = (iy*w+ix)*3+channel
    rgb = image['rgb']
    return ((rgb[p]*(1-fx)+rgb[p+3]*fx)*(1-fy)
            +(rgb[p+w*3]*(1-fx)+rgb[p+w*3+3]*fx)*fy)

def fit(training, affine):
    if len(training) < 20:
        return None
    x, y = zip(*training)
    mx, my = statistics.mean(x), statistics.mean(y)
    variance = sum((v-mx)**2 for v in x)
    if variance < len(x)*1e-6:
        return None
    if affine == 'medianRatio':
        gain = 2**statistics.median(math.log2(v/u) for u,v in training)
    elif affine == 'meanLogRatio':
        gain = 2**statistics.mean(math.log2(v/u) for u,v in training)
    elif affine == 'meanLightRatio':
        gain = my/mx
    else:
        gain = (sum((u-mx)*(v-my) for u, v in training)/variance if affine is True
                else sum(u*v for u, v in training)/sum(u*u for u in x))
    offset = my-gain*mx if affine is True else 0
    if not (0.25 <= gain <= 4 and abs(offset) <= 0.08):
        return None
    return gain, offset

def validate(pairs, affine):
    errors, parameters = [], []
    for parity in [0, 1]:
        training = [(x, y) for x, y, p in pairs if p == parity]
        held = [(x, y) for x, y, p in pairs if p != parity]
        fitted = fit(training, affine)
        if fitted is None or len(held) < 20:
            return None
        gain, offset = fitted
        predicted = [gain*x+offset for x, _ in held]
        if any(y <= 0 for y in predicted):
            return None
        errors += [math.log2(pred/y) for pred, (_, y) in zip(predicted, held)]
        parameters.append({'gain': gain, 'offset': offset})
    return {'heldOutRMSEV': math.sqrt(statistics.mean(e*e for e in errors)),
            'maximumHeldOutErrorEV': max(map(abs, errors)), 'foldParameters': parameters,
            'supportedPixels': len(pairs)}

def validate_plane(pixels):
    """Fit log2(reference/source) = EV + slopeX*x + slopeY*y."""
    errors, parameters = [], []
    for parity in [0,1]:
        train = [(x,y,dx,dy) for x,y,dx,dy in pixels if fold(dx,dy) == parity]
        held = [(x,y,dx,dy) for x,y,dx,dy in pixels if fold(dx,dy) != parity]
        if min(len(train),len(held)) < 20:
            return None
        matrix = [[0.0]*4 for _ in range(3)]
        for x,y,dx,dy in train:
            basis = [1.0,dx,dy]; target = math.log2(y/x)
            for i in range(3):
                for j in range(3): matrix[i][j] += basis[i]*basis[j]
                matrix[i][3] += basis[i]*target
        for i in range(3):
            pivot = max(range(i,3),key=lambda j:abs(matrix[j][i]))
            matrix[i],matrix[pivot] = matrix[pivot],matrix[i]
            if abs(matrix[i][i]) < 1e-9: return None
            divisor = matrix[i][i]
            matrix[i] = [v/divisor for v in matrix[i]]
            for j in range(3):
                if j != i:
                    factor = matrix[j][i]
                    matrix[j] = [a-factor*b for a,b in zip(matrix[j],matrix[i])]
        ev,sx,sy = [matrix[i][3] for i in range(3)]
        if abs(ev)>2 or max(abs(sx),abs(sy))>0.2: return None
        errors += [ev+sx*dx+sy*dy-math.log2(y/x) for x,y,dx,dy in held]
        parameters.append({'ev':ev,'slopeX':sx,'slopeY':sy})
    return {'heldOutRMSEV':math.sqrt(statistics.mean(e*e for e in errors)),
            'maximumHeldOutErrorEV':max(map(abs,errors)), 'foldParameters':parameters,
            'supportedPixels':len(pixels)}

# Analytic sanity check: gain and gradient must survive both held-out folds.
analytic = [(0.15,0.15*2**(0.3+0.025*x-0.017*y),x,y) for y in range(-6,7) for x in range(-6,7)]
assert validate_plane(analytic)['heldOutRMSEV'] < 1e-12

rows = []
candidates = tracking['fallbackProvenance']
if args.all_tracks:
    candidates = []
    for index,track in enumerate(tracking['tracks']):
        observations = {p['frame']:p for p in track['observations']}
        for frame,p in observations.items():
            if frame-1 in observations:
                candidates.append({'track':index,'frame':frame,'x':p['x'],'y':p['y'],'rgbSupport':None})
for candidate in candidates:
    i, frame = candidate['track'], candidate['frame']
    view = {p['frame']: p for p in tracking['tracks'][i]['observations']}
    if frame-1 not in view or frame not in view:
        continue
    before, after = view[frame-1], view[frame]
    assert (after['x'], after['y']) == (candidate['x'], candidate['y'])
    a, b = images[args.first_frame+frame-1], images[args.first_frame+frame]
    channels = []
    for channel in range(3):
        pairs, pixels = [], []
        for dy in range(-6, 7):
            for dx in range(-6, 7):
                x = sample(a, before['x']+before['offsetX']+dx, before['y']+before['offsetY']+dy, channel)
                y = sample(b, after['x']+after['offsetX']+dx, after['y']+after['offsetY']+dy, channel)
                if x is not None and y is not None and 0.003 < x < 0.8 and 0.003 < y < 0.8:
                    pairs.append((x, y, fold(dx,dy)))
                    pixels.append((x,y,dx,dy))
        channels.append({'channel': channel, 'logLightingPlane':validate_plane(pixels), 'gainOnly': validate(pairs, False),
                         'gainAndOffset': validate(pairs, True), **{model: validate(pairs,model) for model in ['medianRatio','meanLogRatio','meanLightRatio']}})
    rows.append({'track': i, 'sourceFrames': [args.first_frame+frame-1, args.first_frame+frame],
                 'position': [after['x'], after['y']], 'originalRGBSupport': candidate['rgbSupport'],
                 'channels': channels})

summary = []
for channel in range(3):
    comparable = [(r['channels'][channel]['gainOnly'], r['channels'][channel]['gainAndOffset']) for r in rows
                  if r['channels'][channel]['gainOnly'] is not None and r['channels'][channel]['gainAndOffset'] is not None]
    summary.append({'channel': channel, 'comparablePatches': len(comparable),
                    'medianGainOnlyHeldOutRMSEV': statistics.median(a['heldOutRMSEV'] for a, b in comparable) if comparable else None,
                    'medianAffineHeldOutRMSEV': statistics.median(b['heldOutRMSEV'] for a, b in comparable) if comparable else None,
                    'affineImprovementCount': sum(b['heldOutRMSEV'] < a['heldOutRMSEV'] for a, b in comparable)})
robustSummary = []
for channel in range(3):
    for model in ['medianRatio','meanLogRatio','meanLightRatio']:
        paired = [(r['channels'][channel]['gainOnly'],r['channels'][channel][model]) for r in rows
                  if r['channels'][channel]['gainOnly'] is not None and r['channels'][channel][model] is not None]
        robustSummary.append({'channel': channel,'model':model,'comparablePatches':len(paired),
            'medianHeldOutRMSEV':statistics.median(b['heldOutRMSEV'] for a,b in paired) if paired else None,
            'improvementCountAgainstGainOnly':sum(b['heldOutRMSEV']<a['heldOutRMSEV'] for a,b in paired)})
report = {'robustSummary':robustSummary,'status': 'Diagnostic only; no correction improvement established.', 'thumbnails': str(args.thumbnails),
          'tracking': str(args.tracking), 'firstFrame': args.first_frame, 'selection': 'all retained adjacent edges' if args.all_tracks else 'luminance fallback edges',
          'validation': f'Two {args.fold} folds of 13x13 registered source patches; each pixel held out once. Pixels near floor/clipping excluded in all models.',
          'bounds': {'gain': [0.25, 4], 'absoluteOffset': 0.08, 'minimumTrainingVariance': 1e-6},
          'limitations': 'Adjacent pixels are correlated. Frozen matches were selected using source images. A better affine fit does not prove additive illumination, identity, safe rendering or useful temporal targets.',
          'summary': summary, 'patches': rows}
args.output.write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(robustSummary, indent=2))
