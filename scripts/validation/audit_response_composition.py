"""Check response composition on identical frozen three-frame pixel support."""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path
from audit_pixel_response import fit, sample


def geometry(transition):
    mapping = {}
    ambiguous = set()
    for p in transition['sourceSelectedMatchedFootprints']:
        for dy in range(-6, 7):
            for dx in range(-6, 7):
                key = (round(p['x']+dx, 6), round(p['y']+dy, 6))
                target = (p['matchedX']+dx, p['matchedY']+dy)
                if key in mapping and math.dist(mapping[key], target) > .25:
                    ambiguous.add(key)
                else:
                    mapping.setdefault(key, target)
    return {k: v for k, v in mapping.items() if k not in ambiguous}


def analyze(points, width):
    rows = []
    for channel in range(3):
        for side in (False, True):
            selected = [p for p in points if (p['position'][0] >= width/2) == side]
            if len(selected) < 24:
                continue
            def model(i, j):
                return fit([{'source': p['rgb'][i], 'target': p['rgb'][j]}
                            for p in selected], channel)
            ab, bc, ac, ba = model(0, 1), model(1, 2), model(0, 2), model(1, 0)
            if any(m is None for m in (ab, bc, ac, ba)):
                continue
            beta = ab[0]*bc[0]
            alpha = bc[0]*ab[1]+bc[1]
            errors = [(beta-ac[0])*math.log2(p['rgb'][0][channel])+alpha-ac[1]
                      for p in selected]
            rows.append({'channel': channel, 'rightHalf': side,
                         'pixels': len(selected), 'AB': ab[:2], 'BC': bc[:2],
                         'AC': ac[:2], 'BA': ba[:2],
                         'composedBeta': beta, 'composedAlpha': alpha,
                         'forwardReverseBetaProduct': ab[0]*ba[0],
                         'compositionDifferenceRMSEV': math.sqrt(statistics.mean(e*e for e in errors))})
    return rows


def main():
    p = argparse.ArgumentParser()
    p.add_argument('thumbnails', type=Path)
    p.add_argument('matched', type=Path)
    p.add_argument('output', type=Path)
    p.add_argument('--middle-frame', type=int, required=True)
    a = p.parse_args()
    assert not a.output.exists()
    images = json.loads(a.thumbnails.read_text())
    transitions = json.loads(a.matched.read_text())['transitions']
    frames = [a.middle_frame-1, a.middle_frame, a.middle_frame+1]
    maps = [geometry(next(t for t in transitions if t['frames'] == frames[i:i+2]))
            for i in (0, 1)]
    points = []
    for start, middle in maps[0].items():
        key = tuple(round(v, 6) for v in middle)
        if key not in maps[1]:
            continue
        rgb = [sample(images[f], *xy) for f, xy in
               zip(frames, (start, middle, maps[1][key]))]
        if any(v is None for v in rgb):
            continue
        values = [c for v in rgb for c in v]
        if min(values) <= .003 or max(values) >= .8:
            continue
        points.append({'position': start, 'rgb': rgb})
    # An exact power-response sequence must compose on identical support.
    analytic = []
    for x in range(80):
        value = 2**(-7+(x % 20)*.2)
        b = 2**.1*value**1.12
        c = 2**(-.2)*b**.91
        analytic.append({'position': [x, 0], 'rgb': [[v]*3 for v in (value, b, c)]})
    assert all(r['compositionDifferenceRMSEV'] < 1e-10 and
               abs(r['forwardReverseBetaProduct']-1) < 1e-10
               for r in analyze(analytic, 80))
    report = {'frames': frames, 'uniqueCommonPixels': len(points),
              'channelsAndSpatialHalves': analyze(points, images[frames[0]]['width']),
              'status': 'Diagnostic only; renderer unchanged.',
              'limitations': 'OLS reverse disagreement also reflects noise and regression attenuation. '
              'Pixels are correlated; chained source-selected geometry is not ground truth. '
              'Direct AC photometry uses the same chained coordinates and identical support, '
              'not independently estimated AC registration.',
              'sha256': {str(f): hashlib.sha256(f.read_bytes()).hexdigest()
                         for f in (a.thumbnails, a.matched, Path(__file__),
                                   Path(__file__).with_name('audit_pixel_response.py'))}}
    a.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
