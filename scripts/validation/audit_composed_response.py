"""Apply a mean-preserving response to decoded corrected pixels, offline only."""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path
from audit_pixel_response import fit, sample
from audit_response_composition import geometry


def luminance(rgb):
    return .2126*rgb[0]+.7152*rgb[1]+.0722*rgb[2]


def main():
    p = argparse.ArgumentParser()
    for name in ('source', 'corrected', 'matched', 'output'):
        p.add_argument(name, type=Path)
    p.add_argument('--frame', type=int, required=True)
    p.add_argument('--model', choices=('blue', 'source_luma', 'residual_luma'), default='blue')
    a = p.parse_args()
    assert not a.output.exists()
    source, corrected = [json.loads(f.read_text()) for f in (a.source, a.corrected)]
    transitions = json.loads(a.matched.read_text())['transitions']
    t = next(t for t in transitions if t['frames'] == [a.frame-1, a.frame])
    sa, sb = source[a.frame-1:a.frame+1]
    ca, cb = corrected[a.frame-1:a.frame+1]
    assert (sa['width'], sa['height']) == (cb['width'], cb['height'])
    points = []
    for xy, target in geometry(t).items():
        values = [sample(im, *pos) for im, pos in
                  ((sa, xy), (sb, target), (ca, xy), (cb, target))]
        if any(v is None for v in values):
            continue
        if min(c for v in values for c in v) <= .003 or max(c for v in values for c in v) >= .8:
            continue
        points.append({'position': xy, 'targetPosition': target,
                       'source': values[0], 'target': values[1],
                       'correctedA': values[2], 'correctedB': values[3]})
    rows = []
    for side in (False, True):
        train = [p for p in points if (p['position'][0] >= sa['width']/2) == side]
        held = [p for p in points if (p['position'][0] >= sa['width']/2) != side]
        if min(len(train), len(held)) < 24:
            continue
        # Fit source-only blue response, then preserve the corrected frame's
        # arithmetic blue mean exactly. This also preserves global mean Y.
        if a.model == 'blue':
            beta, alpha, _ = fit(train, 2)
        else:
            source_key, target_key = ('source', 'target') if a.model == 'source_luma' else ('correctedA', 'correctedB')
            luma_points = [{'source': [luminance(point[source_key])]*3,
                            'target': [luminance(point[target_key])]*3} for point in train]
            beta, alpha, _ = fit(luma_points, 0)
        for amount in (0, .25, .5, 1):
            exponent = 1+amount*(1/beta-1)
            rgb = cb['rgb'][:]
            if a.model == 'blue':
                before = statistics.mean(rgb[2::3])
                transformed = [max(0, v)**exponent for v in rgb[2::3]]
                scale = before/statistics.mean(transformed)
                rgb[2::3] = [v*scale for v in transformed]
                difference = statistics.mean(rgb[2::3])-before
            else:
                levels = [luminance(rgb[i:i+3]) for i in range(0, len(rgb), 3)]
                before = statistics.mean(levels)
                transformed = [max(0, v)**exponent for v in levels]
                scale = before/statistics.mean(transformed)
                for index, (level, value) in enumerate(zip(levels, transformed)):
                    gain = value*scale/level if level > 0 else 1
                    for channel in range(3):
                        rgb[index*3+channel] *= gain
                difference = statistics.mean(luminance(rgb[i:i+3])
                                             for i in range(0, len(rgb), 3))-before
                assert abs(difference) < 1e-12
            candidate = {**cb, 'rgb': rgb}
            errors = {'blue': [], 'luma': [], 'blueGreen': []}
            for point in held:
                left = point['correctedA']
                right = sample(candidate, *point['targetPosition'])
                errors['blue'].append(math.log2(right[2]/left[2]))
                errors['blueGreen'].append(math.log2((right[2]/right[1])/(left[2]/left[1])))
                errors['luma'].append(math.log2(luminance(right)/luminance(left)))
            footprint_steps = []
            for footprint in t['sourceSelectedMatchedFootprints']:
                if (footprint['x'] >= sa['width']/2) == side:
                    continue
                left_values, right_values = [], []
                for dy in range(-6, 7):
                    for dx in range(-6, 7):
                        left = sample(ca, footprint['x']+dx, footprint['y']+dy)
                        right = sample(candidate, footprint['matchedX']+dx, footprint['matchedY']+dy)
                        if left is not None and right is not None:
                            left_values.append(luminance(left))
                            right_values.append(luminance(right))
                if len(left_values) == 169:
                    footprint_steps.append(math.log2(statistics.mean(right_values)/statistics.mean(left_values)))
            rows.append({'trainingRight': side, 'sourceBeta': beta,
                         'sourceAlphaNotApplied': alpha, 'amount': amount,
                         'exponent': exponent, 'heldOutPixels': len(held),
                         'preservedMeanDifference': difference,
                         'heldOutFootprints': len(footprint_steps),
                         'heldOutFootprintMedianAbsoluteLumaEV': statistics.median(map(abs, footprint_steps)) if footprint_steps else None,
                         'heldOutRMSEV': {k: math.sqrt(statistics.mean(v*v for v in values))
                                         for k, values in errors.items()}})
    report = {'model': a.model, 'frames': [a.frame-1, a.frame], 'uniquePixels': len(points), 'rows': rows,
              'status': 'Offline diagnostic, not an exported video or production integration.',
              'limitations': 'Applies response after thumbnail downsampling, not at full source resolution. '
              'Only target frame is transformed; no temporal target solved. Source-selected '
              'geometry may include changing texture. Mean preservation does not preserve local brightness.',
              'sha256': {str(f): hashlib.sha256(f.read_bytes()).hexdigest()
                         for f in (a.source, a.corrected, a.matched, Path(__file__))}}
    a.output.write_text(json.dumps(report, indent=2)+'\n')
    print(json.dumps({'frames': report['frames'], 'rows': rows}, indent=2))


if __name__ == '__main__':
    main()
