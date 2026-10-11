#!/usr/bin/env python3
"""Source-only, spatially held similarity transforms from native-checked landmarks.

This tests motion coherence, not unique printed identity or illumination. Never
uses corrected output or changes image pixels. Unsupported probes remain so.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def fit_similarity(points):
    if len(points) < 3:
        return None
    source = [complex(*p['source']) for p in points]
    target = [complex(*p['target']) for p in points]
    sm, tm = sum(source) / len(source), sum(target) / len(target)
    centered = [z - sm for z in source]
    xx = sum(z.real ** 2 for z in centered) / len(source)
    yy = sum(z.imag ** 2 for z in centered) / len(source)
    xy = sum(z.real * z.imag for z in centered) / len(source)
    minimum_variance = (xx + yy - math.hypot(xx - yy, 2 * xy)) / 2
    # Require independently spread edges, not a line of repeated print.
    if minimum_variance < 400:
        return None
    scale_rotation = sum((z-sm).conjugate()*(q-tm) for z, q in zip(source, target)) / sum(abs(z) ** 2 for z in centered)
    translation = tm - scale_rotation * sm
    if not 0.9 <= abs(scale_rotation) <= 1.1 or abs(math.degrees(math.atan2(scale_rotation.imag, scale_rotation.real))) > 5:
        return None
    return scale_rotation, translation


def predict(model, point):
    return model[0] * complex(*point) + model[1]


def assess(points, block_pixels=320):
    # Spatial blocks, fixed before residual evaluation. Never select a good held
    # subset or fit all points and report its residual as independent evidence.
    groups = [[p for p in points if (math.floor(p['source'][0]/block_pixels) + math.floor(p['source'][1]/block_pixels)) % 2 == fold] for fold in (0, 1)]
    models = [fit_similarity(group) for group in groups]
    result = {'landmarks': len(points), 'foldSizes': [len(g) for g in groups],
              'spatialBlockPixels': block_pixels, 'qualified': False, 'rejection': 'insufficientSpatiallySpreadLandmarks'}
    if any(m is None for m in models):
        return result
    held = [abs(predict(models[fold], p['source']) - complex(*p['target'])) for fold in (0, 1) for p in groups[1-fold]]
    agreement = [abs(predict(models[0], p['source']) - predict(models[1], p['source'])) for p in points]
    result.update(maximumHeldErrorPixels=max(held), maximumModelDisagreementPixels=max(agreement),
                  transforms=[{'a': m[0].real, 'b': m[0].imag, 'tx': m[1].real, 'ty': m[1].imag} for m in models])
    result['qualified'] = max(held) <= 1 and max(agreement) <= 1
    result['rejection'] = None if result['qualified'] else 'heldLandmarkOrTransformDisagreement'
    return result


def self_test():
    source = [(x, y) for y in (100, 260, 420, 580) for x in (100, 260, 420, 580)]
    model = complex(math.cos(0.02), math.sin(0.02)), complex(2, -3)
    points = [{'source': p, 'target': [predict(model, p).real, predict(model, p).imag]} for p in source]
    assert assess(points)['qualified']
    changed = [dict(p) for p in points]
    changed[0] = dict(changed[0], target=[1000, 1000])
    assert not assess(changed)['qualified']
    assert fit_similarity([{'source': [x, 100], 'target': [x+2, 100]} for x in range(0, 1000, 100)]) is None
    assert not assess(points[:2])['qualified']
    assert max(abs(predict(fit_similarity(points), p['source']) - complex(*p['target'])) for p in points) < 1e-10
    print('LANDMARK_TRANSFORM_SELF_TEST_PASS')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('diagnostic', nargs='?', type=Path)
    parser.add_argument('native', nargs='?', type=Path)
    parser.add_argument('output', nargs='?', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not all((args.diagnostic, args.native, args.output)):
        parser.error('diagnostic native fresh-output required')
    diagnostic = json.loads(args.diagnostic.read_text())
    native = json.loads(args.native.read_text())
    assert diagnostic['source'] == native['source']
    assert native['nativeCornersValidatedBeforeInterpolation']
    assert (native['edgeGeometryProbe'] and native['boxGeometryProbe']) or native.get('luminanceGeometryProbe')
    boxes = native['nonoverlappingSupportEnvelopes']
    assert len(boxes) == len(native['rows'])
    assert all(a[2] < b[0] or b[2] < a[0] or a[3] < b[1] or b[3] < a[1]
               for i, a in enumerate(boxes) for b in boxes[i+1:])
    histories = {(r['analysisX'], r['analysisY']): {p['frame']: p for p in r.get('history', [])}
                 for r in diagnostic['diagnosticRows']}
    def position(point):
        return [(point['analysisX']+.5)*native['nativeSize'][0]/diagnostic['analysisWidth']-.5,
                (point['analysisY']+.5)*native['nativeSize'][1]/diagnostic['analysisHeight']-.5]
    pairs = []
    for frame in range(diagnostic['first'], diagnostic['endExclusive']-1):
        points = []
        for row in native['rows']:
            check = next((c for c in row['checks'] if c['frames'] == [frame, frame+1]), None)
            if check is None or check['reason'] != 'accepted':
                continue
            key = row['analysisX'], row['analysisY']
            history = histories[key]
            # Preserve nominal transported positions; never use a diagnostic
            # local refinement to change the brightness meter or a fit target.
            points.append({'seed': list(key), 'source': position(history[frame]), 'target': position(history[frame+1])})
        result = assess(points, max(80, min(320, native['nativeSize'][0]/4)))
        result.update(frames=[frame, frame+1], sourceLandmarks=points)
        pairs.append(result)
    result = {'source': diagnostic['source'], 'pairs': pairs, 'heldToleranceNativePixels': 1,
              'sha256': {str(p): digest(p) for p in (args.diagnostic, args.native, Path(__file__))},
              'limitation': 'Diagnostic coherence of source trajectories already checked on separate native edges. Fixed spatial folds, unchanged nominal positions, no pixel warp. Does not certify unique printed identity, a rigid object, untested query locations, illumination, dark noise, or correction. No geometry is propagated into unsupported meters.'}
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write('\n')
    print([(p['frames'], p['landmarks'], p['qualified'], p['rejection']) for p in pairs])


if __name__ == '__main__':
    main()
