#!/usr/bin/env python3
"""Source-only shared response hypotheses with entire native patches held out.

No rendered output, donor substitution, pixel warp or correction authorisation.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path

WEIGHTS = (.2126, .7152, .0722)
MODELS = ('luminance-affine', 'spectral-offset', 'rgb-affine', 'luminance-log-tone', 'rgb-log-tone')


def y(rgb):
    return sum(a*b for a, b in zip(WEIGHTS, rgb))


def regress(features, target):
    n = len(features[0])
    means = [sum(row[c] for row in features)/len(features) for c in range(n-1)] + [0]
    scales = [math.sqrt(sum((row[c]-means[c])**2 for row in features)/len(features)) for c in range(n-1)] + [1]
    if any(s < 1e-6 for s in scales):
        return None
    rows = [[(v-means[c])/scales[c] for c, v in enumerate(row)] for row in features]
    matrix = [[sum(row[i]*row[j] for row in rows) for j in range(n)] + [sum(row[i]*z for row, z in zip(rows, target))] for i in range(n)]
    for c in range(n):
        pivot = max(range(c, n), key=lambda r: abs(matrix[r][c]))
        if abs(matrix[pivot][c]) < len(features)*1e-8:
            return None
        matrix[c], matrix[pivot] = matrix[pivot], matrix[c]
        divisor = matrix[c][c]
        matrix[c] = [v/divisor for v in matrix[c]]
        for r in range(n):
            if r != c:
                multiplier = matrix[r][c]
                matrix[r] = [a-multiplier*b for a, b in zip(matrix[r], matrix[c])]
    coefficients = [matrix[c][-1]/scales[c] for c in range(n)]
    coefficients[-1] -= sum(coefficients[c]*means[c] for c in range(n-1))
    return coefficients


def fit(samples, model):
    if model == 'luminance-affine':
        coeff = regress([[y(a), 1] for a, _ in samples], [y(b) for _, b in samples])
        return coeff if coeff and .25 <= coeff[0] <= 4 and abs(coeff[1]) <= .05 else None
    if model == 'spectral-offset':
        coeff = regress([[a[c]*WEIGHTS[c] for c in range(3)]+[1] for a, _ in samples], [y(b) for _, b in samples])
        return coeff if coeff and all(.25 <= v <= 4 for v in coeff[:3]) and abs(coeff[3]) <= .05 else None
    if model == 'rgb-affine':
        coeff = [regress([[a[c], 1] for a, _ in samples], [b[c] for _, b in samples]) for c in range(3)]
        return coeff if all(v and .25 <= v[0] <= 4 and abs(v[1]) <= .05 for v in coeff) else None
    if model == 'luminance-log-tone':
        coeff = regress([[math.log2(y(a)), 1] for a, _ in samples], [math.log2(y(b)) for _, b in samples])
        return coeff if coeff and .5 <= coeff[0] <= 2 and abs(coeff[1]) <= 4 else None
    if model == 'rgb-log-tone':
        if any(v <= 0 for a, b in samples for v in a+b):
            return None
        coeff = [regress([[math.log2(a[c]), 1] for a, _ in samples], [math.log2(b[c]) for _, b in samples]) for c in range(3)]
        return coeff if all(v and .5 <= v[0] <= 2 and abs(v[1]) <= 4 for v in coeff) else None
    raise ValueError(model)


def predict(a, model, coeff):
    if model == 'luminance-affine':
        return coeff[0]*y(a)+coeff[1]
    if model == 'spectral-offset':
        return sum(coeff[c]*a[c]*WEIGHTS[c] for c in range(3))+coeff[3]
    if model == 'rgb-affine':
        rgb = [coeff[c][0]*a[c]+coeff[c][1] for c in range(3)]
    elif model == 'luminance-log-tone':
        return 2**(coeff[0]*math.log2(y(a))+coeff[1])
    elif model == 'rgb-log-tone':
        if any(v <= 0 for v in a):
            return None
        rgb = [2**(coeff[c][0]*math.log2(a[c])+coeff[c][1]) for c in range(3)]
    else:
        raise ValueError(model)
    return y(rgb) if all(0 <= v < .95 for v in rgb) else None


def evaluate(patches, model, minimum_patches=6):
    result = {'model': model, 'qualified': False, 'patches': len(patches), 'rejection': 'insufficientIndependentPatches'}
    if len(patches) < minimum_patches:
        return result
    folds, predictions = [], []
    for index, patch in enumerate(patches):
        training = [sample for i, p in enumerate(patches) if i != index for sample in p['samples']]
        coeff = fit(training, model)
        if coeff is None:
            result['rejection'] = 'unidentifiableOrUnboundedFit'
            return result
        held = [predict(a, model, coeff) for a, _ in patch['samples']]
        if any(v is None or not .005 < v < .95 for v in held):
            result['rejection'] = 'invalidHeldPrediction'
            return result
        errors = [abs(math.log2(v/y(b))) for v, (_, b) in zip(held, patch['samples'])]
        folds.append({'heldSeed': patch['seed'], 'coefficients': coeff, 'maximumHeldErrorEV': max(errors)})
        all_predictions = [predict(a, model, coeff) for p in patches for a, _ in p['samples']]
        if any(v is None or not .005 < v < .95 for v in all_predictions):
            result['rejection'] = 'invalidInteriorPrediction'
            return result
        predictions.append(all_predictions)
    agreement = max(math.log2(max(values)/min(values)) for values in zip(*predictions))
    maximum_held = max(f['maximumHeldErrorEV'] for f in folds)
    result.update(folds=folds, maximumHeldErrorEV=maximum_held, maximumPredictionDisagreementEV=agreement)
    result['qualified'] = maximum_held <= .04 and agreement <= .04
    result['rejection'] = None if result['qualified'] else 'heldResponseOrModelDisagreement'
    return result


def self_test():
    patches = []
    for p in range(6):
        samples = []
        for i in range(25):
            a = [.03+.003*((i*7+p*3)%31), .04+.002*((i*11+p)%37), .02+.002*((i*13+p*5)%29)]
            b = [1.3*a[0]+.003, 1.1*a[1]+.002, .9*a[2]+.001]
            samples.append((a, b))
        patches.append({'seed': [p, 0], 'samples': samples})
    assert evaluate(patches, 'rgb-affine')['qualified']
    assert evaluate(patches, 'spectral-offset')['qualified']
    changed = [dict(p) for p in patches]
    changed[0] = dict(changed[0], samples=[(a, [v*1.2 for v in b]) for a, b in changed[0]['samples']])
    assert not evaluate(changed, 'rgb-affine')['qualified']
    assert regress([[.1, .1, 1] for _ in range(25)], [.2]*25) is None
    assert not evaluate(patches[:5], 'rgb-affine')['qualified']
    print('NATIVE_SHARED_RESPONSE_SELF_TEST_PASS')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native', nargs='?', type=Path)
    parser.add_argument('output', nargs='?', type=Path)
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--refined', action='store_true', help='Use source-only reciprocal/triangle-checked native geometry refinement')
    parser.add_argument('--local', action='store_true', help='Hold out each complete native tile row within one patch; no shared-camera assertion')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not all((args.native, args.output)):
        parser.error('native fresh-output required')
    native = json.loads(args.native.read_text())
    assert native['nativeMeterExport'] and native['nativeCornersValidatedBeforeInterpolation']
    assert not args.refined or native['nativeRefinedMeterProbe']
    events = sorted({p['event'] for r in native['rows'] for p in r['pulses']})
    reports = []
    for event in events:
        patches, exclusions = [], {'geometry': 0, 'invalidOrClipped': 0, 'dark': 0}
        for row in native['rows']:
            pulse = next((p for p in row['nativeRefinedBrackets' if args.refined else 'pulses'] if p['event'] == event), None)
            if pulse is None or not pulse['geometryQualified']:
                exclusions['geometry'] += 1
                continue
            if args.refined:
                selected = [{'rgb': rgb, 'pts': pts} for rgb, pts in zip(pulse['rgb'], pulse['pts'])]
            else:
                frames = {f['frame']: f for f in row['nativeMeterFrames']}
                selected = [frames[event+d] for d in (-1, 0, 1)]
            if any(f['rgb'] is None for f in selected):
                exclusions['invalidOrClipped'] += 1
                continue
            rgb = [[f['rgb'][i:i+3] for i in range(0, 75, 3)] for f in selected]
            if any(y(tile) <= .005 for image in rgb for tile in image):
                exclusions['dark'] += 1
                continue
            alpha = (selected[1]['pts']-selected[0]['pts'])/(selected[2]['pts']-selected[0]['pts'])
            samples = [([(1-alpha)*a[c]+alpha*z[c] for c in range(3)], b) for a, b, z in zip(*rgb)]
            patches.append({'seed': [row['analysisX'], row['analysisY']], 'samples': samples})
        if args.local:
            local = []
            for patch in patches:
                rows = [{'seed': [index, 0], 'samples': patch['samples'][index*5:(index+1)*5]} for index in range(5)]
                models = [evaluate(rows, model, minimum_patches=5) for model in MODELS]
                for model in models:
                    if model['qualified']:
                        coeff = fit(patch['samples'], model['model'])
                        model['fullPatchCoefficients'] = coeff
                        model['integratedSourceExcursionEV'] = math.log2(sum(y(b) for _, b in patch['samples']) / sum(y(a) for a, _ in patch['samples']))
                local.append({'seed': patch['seed'], 'models': models})
            reports.append({'event': event, 'retainedPatches': [p['seed'] for p in patches], 'exclusions': exclusions, 'localPatches': local})
        else:
            reports.append({'event': event, 'retainedPatches': [p['seed'] for p in patches], 'exclusions': exclusions,
                            'models': [evaluate(patches, model) for model in MODELS]})
    result = {'source': native['source'], 'localRowFolds': args.local, 'nativeRefinement': args.refined, 'events': reports,
              'sha256': {str(p): digest(p) for p in (args.native, Path(__file__))},
              'limitation': 'Local mode holds out disjoint complete tile rows inside one native patch; it does not assert shared illumination or cross-patch prediction. Source-only response hypotheses. Leave-one-whole-disjoint-native-patch-out checks; source geometry remains the native diagnostic, not uniquely identified material. No dark/clipped contributions. Broad gain range [0.25,4] is an experimental envelope, not an app limit change. Successful prediction alone does not identify unwanted lighting, establish calibrated noise or authorise correction. No rendered fit or encoded acceptance.'}
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write('\n')
    if args.local:
        print([(e['event'], [(p['seed'], [m['model'] for m in p['models'] if m['qualified']]) for p in e['localPatches'] if any(m['qualified'] for m in p['models'])]) for e in reports])
    else:
        print([(e['event'], len(e['retainedPatches']), [(m['model'], m['qualified'], m.get('maximumHeldErrorEV', m['rejection'])) for m in e['models']]) for e in reports])


if __name__ == '__main__':
    main()
