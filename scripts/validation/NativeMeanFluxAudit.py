#!/usr/bin/env python3
"""Research regional radiance meters with leave-query-out temporal corroboration.

Allows nonuniform response inside a tracked patch. This is a different hypothesis
from pixel-response validation, not acceptance by relaxing that validator.
"""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path


def clock(values, margins):
    if len(values) < 4:
        return 'unknown', None
    if all(abs(v)+2*e <= .01 for v, e in zip(values, margins)):
        return 'quiet', statistics.median(values)
    half = len(values)//2
    left, right = statistics.median(values[:half]), statistics.median(values[half:])
    event, margin = statistics.median(values), statistics.median(margins)
    if left*right > 0 and min(abs(left), abs(right)) > max(.03, 2*margin) and abs(event) > .03:
        return 'event', event
    return 'unknown', None


def classify(measures):
    ordered = sorted(measures, key=lambda m: m['seed'])
    for query in ordered:
        donors = [m for m in ordered if m is not query]
        state, excursion = clock([m['sourcePulse'] for m in donors], [m['guardMarginEV'] for m in donors])
        query['donorCount'] = len(donors)
        query['corroborationState'] = state
        query['donorExcursionEV'] = excursion
        query['active'] = (state == 'event' and query['sourcePulse']*excursion > 0
                           and abs(query['sourcePulse']) > max(.08, 3*query['guardMarginEV']))
    return ordered


def self_test():
    pulse = [{'seed': [i, 0], 'sourcePulse': .35+.12*i, 'guardMarginEV': .02} for i in range(5)]
    assert all(m['active'] for m in classify(pulse))
    motion = [{'seed': [i, 0], 'sourcePulse': .8 if i == 0 else 0, 'guardMarginEV': .01} for i in range(5)]
    assert not any(m['active'] for m in classify(motion))
    fade = [{'seed': [i, 0], 'sourcePulse': 0, 'guardMarginEV': .01} for i in range(5)]
    assert not any(m['active'] for m in classify(fade))
    assert not any(m['active'] for m in classify(pulse[:4]))
    conflicting = [{'seed': [i, 0], 'sourcePulse': .4 if i < 2 else -.4, 'guardMarginEV': .01} for i in range(5)]
    assert not all(m['active'] for m in classify(conflicting))
    print('NATIVE_MEAN_FLUX_CORROBORATION_SELF_TEST_PASS')


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('native', nargs='?', type=Path)
    parser.add_argument('diagnostic', nargs='?', type=Path)
    parser.add_argument('output', nargs='?', type=Path)
    parser.add_argument('--self-test', action='store_true')
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not all((args.native, args.diagnostic, args.output)):
        parser.error('native diagnostic fresh-output required')
    native, diagnostic = [json.loads(p.read_text()) for p in (args.native, args.diagnostic)]
    assert native['nativeRefinedMeterProbe'] and native['nativeMeterExport'] and native['nativeCornersValidatedBeforeInterpolation']
    assert native['source'] == diagnostic['source']
    boxes = native['nonoverlappingSupportEnvelopes']
    assert len(boxes) == len(native['rows'])
    assert all(a[2] < b[0] or b[2] < a[0] or a[3] < b[1] or b[3] < a[1] for i, a in enumerate(boxes) for b in boxes[i+1:])
    histories = {(r['analysisX'], r['analysisY']): {p['frame']: p for p in r.get('history', [])} for r in diagnostic['diagnosticRows']}
    groups = {}
    nw, nh = native['nativeSize']
    for row in native['rows']:
        seed = row['analysisX'], row['analysisY']
        for bracket in row['nativeRefinedBrackets']:
            stress = bracket.get('integratedPulseStress')
            if not bracket['geometryQualified'] or stress is None:
                continue
            event = bracket['event']
            images = []
            for k, rgb in enumerate(bracket['rgb']):
                frame = event+k-1
                assert abs(bracket['pts'][k]-diagnostic['times'][frame-diagnostic['first']]) < 1e-8
                assert len(rgb) == 75 and all(math.isfinite(v) and 0 <= v < .95 for v in rgb)
                assert all(sum(a*b for a, b in zip((.2126, .7152, .0722), rgb[i:i+3])) > .005 for i in range(0, 75, 3))
                point = histories[seed][frame]
                ox, oy = bracket['nativeOffsets'][k]
                cx = (point['analysisX']+.5)/diagnostic['analysisWidth']+ox/nw
                cy = (point['analysisY']+.5)/diagnostic['analysisHeight']+oy/nh
                positions = [[cx+5*dx/nw, cy+5*dy/nh] for dy in range(-2, 3) for dx in range(-2, 3)]
                images.append({'frame': frame, 'pts': bracket['pts'][k], 'rgb': rgb, 'positions': positions})
            groups.setdefault(event, []).append({'event': event, 'seed': list(seed), 'sourcePulse': stress['nominalEV'],
                'guardMarginEV': stress['maximumChangeEV']+.01, 'geometryStress': stress, 'images': images})
    measures = [m for event in sorted(groups) for m in classify(groups[event])]
    result = {'source': native['source'], 'first': diagnostic['first'], 'endExclusive': diagnostic['endExclusive'],
              'measurements': measures, 'sha256': {str(p): digest(p) for p in (args.native, args.diagnostic, Path(__file__))},
              'limitation': 'Research integrated regional-radiance hypothesis. All central native contributors and tile luminance gates remain. Reciprocal/triangle source geometry and disjoint envelopes remain. Local shape-passing position stress plus a fixed 0.01EV research margin is not a calibrated sensor-noise bound. Independent spatial donor folds corroborate timing/sign, not amplitude, unique material identity or unwanted lighting. Allows spatially nonuniform light response inside a patch; does not satisfy the old uniform pixel-response criterion. A candidate still needs encoded neighboring-frame and known-motion/fade/control acceptance before integration.'}
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write('\n')
    print([(event, len(group), sum(m['active'] for m in group)) for event, group in sorted(groups.items())])


if __name__ == '__main__':
    main()
