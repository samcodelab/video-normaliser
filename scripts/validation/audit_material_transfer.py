"""Test material-conditioned gains on spatially withheld whole footprints."""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path
from audit_pixel_response import sample


def mean(image, x, y):
    values = [sample(image, x+dx, y+dy) for dy in range(-6, 7) for dx in range(-6, 7)]
    if any(v is None for v in values):
        return None
    rgb = [statistics.mean(v[c] for v in values) for c in range(3)]
    return rgb if min(rgb) > .003 and max(rgb) < .8 else None


def weighted_median(values):
    total = sum(w for _, w in values)
    accumulated = 0
    for value, weight in sorted(values):
        accumulated += weight
        if accumulated >= total/2:
            return value


def main():
    p = argparse.ArgumentParser()
    for name in ('source', 'corrected', 'matched', 'output'):
        p.add_argument(name, type=Path)
    p.add_argument('--frame', type=int, required=True)
    a = p.parse_args()
    assert not a.output.exists()
    source, corrected = [json.loads(f.read_text()) for f in (a.source, a.corrected)]
    transition = next(t for t in json.loads(a.matched.read_text())['transitions']
                      if t['frames'] == [a.frame-1, a.frame])
    points = []
    for f in transition['sourceSelectedMatchedFootprints']:
        values = [mean(im, x, y) for im, x, y in (
            (source[a.frame-1], f['x'], f['y']), (source[a.frame], f['matchedX'], f['matchedY']),
            (corrected[a.frame-1], f['x'], f['y']), (corrected[a.frame], f['matchedX'], f['matchedY']))]
        if any(v is None for v in values):
            continue
        s, t, ca, cb = values
        points.append({'x': f['x'], 'chroma': [math.log2(s[0]/s[1]), math.log2(s[2]/s[1])],
                       'sourceStep': [math.log2(t[c]/s[c]) for c in range(3)],
                       'correctedStep': [math.log2(cb[c]/ca[c]) for c in range(3)]})
    rows = []
    for side in (False, True):
        train = [q for q in points if (q['x'] >= source[a.frame]['width']/2) == side]
        held = [q for q in points if q not in train]
        if min(len(train), len(held)) < 6:
            continue
        for radius in (.5, 1, 2):
            supported = []
            for q in held:
                neighbors = [(v, math.dist(v['chroma'], q['chroma'])) for v in train]
                neighbors = [(v, math.exp(-.5*(d/radius)**2)) for v, d in neighbors if d < radius*2]
                if len(neighbors) < 3:
                    continue
                prediction = [weighted_median([(v['sourceStep'][c], weight) for v, weight in neighbors]) for c in range(3)]
                supported.append((q, prediction))
            if not supported:
                continue
            global_gain = [statistics.median(v['sourceStep'][c] for v in train) for c in range(3)]
            rms = lambda errors: math.sqrt(statistics.mean(e*e for e in errors))
            rows.append({'trainingRight': side, 'chromaRadiusEV': radius,
                         'trainingFootprints': len(train), 'heldOutFootprints': len(held),
                         'supportedHeldOutFootprints': len(supported),
                         'sourceGlobalGainPredictionRMSEV': rms([q['sourceStep'][c]-global_gain[c] for q, _ in supported for c in range(3)]),
                         'sourceMaterialPredictionRMSEV': rms([q['sourceStep'][c]-pred[c] for q, pred in supported for c in range(3)]),
                         'sourceMaterialChannelRMSEV': [rms([q['sourceStep'][c]-pred[c] for q, pred in supported]) for c in range(3)],
                         'currentCorrectedChannelRMSEV': [rms([q['correctedStep'][c] for q, _ in supported]) for c in range(3)]})
    report = {'frames': [a.frame-1, a.frame], 'footprints': len(points), 'rows': rows,
              'status': 'Diagnostic only; no rendering or temporal targets.',
              'limitations': 'Patch colour is a material proxy, not identity. Overlapping footprints '
              'are correlated. Lighting targets cannot assume every source change is flicker. '
              'Existing correction overlap has not been subtracted.',
              'sha256': {str(f): hashlib.sha256(f.read_bytes()).hexdigest()
                         for f in (a.source, a.corrected, a.matched, Path(__file__))}}
    a.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps(report['rows'], indent=2))


if __name__ == '__main__':
    main()
