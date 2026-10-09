"""Validate a power response on unique, frozen source-selected pixels.

This is a diagnostic, not a production correction or causal camera classifier.
"""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path


def sample(image, x, y):
    w, h = image['width'], image['height']
    ix, iy = math.floor(x), math.floor(y)
    if not (0 <= ix < w - 1 and 0 <= iy < h - 1):
        return None
    fx, fy = x - ix, y - iy
    k, rgb = (iy * w + ix) * 3, image['rgb']
    return [((rgb[k+c]*(1-fx)+rgb[k+3+c]*fx)*(1-fy)
             +(rgb[k+w*3+c]*(1-fx)+rgb[k+w*3+3+c]*fx)*fy)
            for c in range(3)]


def fit(points, channel):
    xs = [math.log2(p['source'][channel]) for p in points]
    ys = [math.log2(p['target'][channel]) for p in points]
    mx, my = statistics.mean(xs), statistics.mean(ys)
    variance = statistics.mean((x-mx)**2 for x in xs)
    if variance < .01:
        return None
    beta = statistics.mean((x-mx)*(y-my) for x, y in zip(xs, ys))/variance
    return beta, my-beta*mx, my-mx


def score(points, channel, beta, alpha):
    # Apply the actual inverse power response to original target pixels.
    corrected = [(p['target'][channel]/2**alpha)**(1/beta) for p in points]
    original = [p['source'][channel] for p in points]
    return {
        'renderedLogRMSEV': math.sqrt(statistics.mean(
            math.log2(c/s)**2 for c, s in zip(corrected, original))),
        'renderedLinearRMSE': math.sqrt(statistics.mean(
            (c-s)**2 for c, s in zip(corrected, original))),
    }


def evaluate(points, width):
    rows = []
    for channel in range(3):
        folds = []
        for side in (False, True):
            train = [p for p in points if (p['position'][0] >= width/2) == side]
            held = [p for p in points if (p['position'][0] >= width/2) != side]
            if min(len(train), len(held)) < 24:
                continue
            model = fit(train, channel)
            if model is None:
                continue
            beta, alpha, gain = model
            folds.append({'trainingRight': side, 'trainingPixels': len(train),
                          'heldOutPixels': len(held), 'beta': beta, 'alpha': alpha,
                          'gain': score(held, channel, 1, gain),
                          'power': score(held, channel, beta, alpha)})
        rows.append({'channel': channel, 'folds': folds})
    return rows


def controls():
    cases = {}
    for name in ('known_gamma', 'exposure_only', 'independent_material_lights'):
        points = []
        for x in range(80):
            for material in range(8):
                # Every spatial half contains every brightness/material family.
                level = 2**(-7+material*.65+(x % 5)*.03)
                if name == 'known_gamma':
                    target = 2**.15*level**1.15
                elif name == 'exposure_only':
                    target = 2**.25*level
                else:
                    # Separate lights correlated with material brightness can
                    # exactly imitate a shared gamma on these observations.
                    target = level*2**(.15+.15*math.log2(level))
                points.append({'position': [x, material], 'source': [level]*3,
                               'target': [target]*3})
        cases[name] = evaluate(points, 80)
    assert abs(cases['known_gamma'][0]['folds'][0]['beta']-1.15) < 1e-10
    assert abs(cases['exposure_only'][0]['folds'][0]['beta']-1) < 1e-10
    assert cases['known_gamma'][0]['folds'][0]['power']['renderedLogRMSEV'] < 1e-10
    assert abs(cases['independent_material_lights'][0]['folds'][0]['beta']-1.15) < 1e-10
    return cases


def grouped_validation(points):
    rows = []
    for kind in ('source_chroma', 'brightness'):
        groups = {}
        for point in points:
            rgb = point['source']
            if kind == 'source_chroma':
                key = (math.floor(math.log2(rgb[0]/rgb[1])),
                       math.floor(math.log2(rgb[2]/rgb[1])))
            else:
                key = (math.floor(math.log2(.2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2])),)
            groups.setdefault(key, []).append(point)
        for key, held in groups.items():
            if len(held) < 128:
                continue
            train = [p for other, values in groups.items() if other != key for p in values]
            if len(train) < 128:
                continue
            for channel in range(3):
                model = fit(train, channel)
                if model is None:
                    continue
                beta, alpha, gain = model
                rows.append({'holdoutKind': kind, 'heldOutBin': key,
                             'heldOutPixels': len(held), 'channel': channel,
                             'beta': beta, 'alpha': alpha,
                             'gain': score(held, channel, 1, gain),
                             'power': score(held, channel, beta, alpha)})
    return rows


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('thumbnails', type=Path)
    parser.add_argument('matched', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--frame', type=int, required=True)
    args = parser.parse_args()
    assert not args.output.exists()
    images = json.loads(args.thumbnails.read_text())
    matched = json.loads(args.matched.read_text())
    source, target = images[args.frame-1], images[args.frame]
    transition = next(t for t in matched['transitions']
                      if t['frames'] == [args.frame-1, args.frame])
    pixels = {}
    conflicts = 0
    for footprint in transition['sourceSelectedMatchedFootprints']:
        for dy in range(-6, 7):
            for dx in range(-6, 7):
                x, y = footprint['x']+dx, footprint['y']+dy
                tx, ty = footprint['matchedX']+dx, footprint['matchedY']+dy
                key = (round(x, 6), round(y, 6))
                if key in pixels:
                    if math.hypot(tx-pixels[key]['targetPosition'][0],
                                  ty-pixels[key]['targetPosition'][1]) > .25:
                        conflicts += 1
                    continue
                s, t = sample(source, x, y), sample(target, tx, ty)
                if s is None or t is None or min(s+t) <= .003 or max(s+t) >= .8:
                    continue
                pixels[key] = {'position': [x, y], 'targetPosition': [tx, ty],
                               'source': s, 'target': t}
    report = {
        'status': 'Diagnostic only; no production change.',
        'sourceFrames': [args.frame-1, args.frame], 'uniquePixels': len(pixels),
        'duplicateMappingConflicts': conflicts,
        'channels': evaluate(list(pixels.values()), source['width']),
        'heldOutBrightnessAndChromaBins': grouped_validation(list(pixels.values())),
        'analyticControls': controls(),
        'limitations': 'Adjacent pixels remain correlated. Geometry was source-selected. '
        'Independent material illumination can be observationally identical to gamma; '
        'spatial fit alone cannot establish a camera response. This tests an isolated '
        'inverse transform, not the existing composed correction pipeline.',
        'sha256': {str(path): hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in (args.thumbnails, args.matched, Path(__file__))},
    }
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({k: report[k] for k in
                      ('sourceFrames', 'uniquePixels', 'duplicateMappingConflicts', 'channels')}, indent=2))


if __name__ == '__main__':
    main()
