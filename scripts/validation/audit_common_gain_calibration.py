#!/usr/bin/env python3
"""Offline calibration of only the baseline gain coupled to source lighting.

Source evidence is frozen before baseline or clean frames are loaded. This does
not modify movies or production code. Unknown source/gain response abstains.
"""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path

import audit_common_illumination as component


def correction(common, source_response, gain_response, strength, penalty):
    if strength == 0:
        return [0.0]*len(common)
    slow = component.smooth(common, penalty)
    return [(strength*source_response-gain_response)*(h-v)
            for h, v in zip(slow, common)]


def gain_fit(x, y):
    """Fit gain increments against correction increments plus constant drift."""
    weights = [1.0]*len(x)
    for _ in range(5):
        total = sum(weights)
        mx = sum(w*v for w, v in zip(weights, x))/total
        my = sum(w*v for w, v in zip(weights, y))/total
        den = sum(w*(v-mx)**2 for w, v in zip(weights, x))
        if den < 1e-12:
            return None
        beta = sum(w*(a-mx)*(b-my) for w, a, b in zip(weights, x, y))/den
        intercept = my-beta*mx
        residual = [b-beta*a-intercept for a, b in zip(x, y)]
        scale = max(.001, 1.4826*component.med([abs(v-component.med(residual)) for v in residual]))
        weights = [min(1.0, 3*scale/max(1e-12, abs(v))) for v in residual]
    return beta, intercept


def gain_validate(x, y, folds, args):
    models, errors, null_errors = [], [], []
    for held in folds:
        train = [i for i in range(len(x)) if i not in held]
        if not any(abs(x[i]) >= args.excitation for i in train) or not any(abs(x[i]) >= args.excitation for i in held):
            return {'passed': False, 'reason': 'unexcited_gain_fold'}
        fitted = gain_fit([x[i] for i in train], [y[i] for i in train])
        if fitted is None:
            return {'passed': False, 'reason': 'singular_gain_response'}
        beta, drift = fitted
        models.append(beta)
        errors.extend(y[i]-beta*x[i]-drift for i in held)
        null_errors.extend(y[i]-drift for i in held)
    fitted = gain_fit(x, y)
    if fitted is None:
        return {'passed': False, 'reason': 'singular_gain_response'}
    beta, drift = fitted
    error, null = component.rms(errors), component.rms(null_errors)
    consistent = max(models)-min(models) <= max(.06, .15*abs(beta))
    absence = abs(beta) <= .03 and max(map(abs, models)) <= .05 and null <= .01
    explained = error <= max(args.agreement, .06*null) and error <= .7*null
    passed = abs(beta) <= 2.5 and consistent and (absence or explained)
    return {'passed': passed, 'coefficient': beta, 'driftPerFrame': drift,
            'foldCoefficients': models, 'heldErrorRMS': error, 'heldNullRMS': null,
            'absence': absence, 'reason': 'validated_gain' if passed else 'gain_validation_failed'}


def score(frozen, original, source, baseline, clean, strength):
    summary, rows = component.score(frozen, original, baseline, clean)
    for row, track in zip(rows, original):
        retained = [(1-strength)*(component.level(source[f], x, y)-component.level(clean[f], x, y))
                    for f, x, y in zip(track['frames'], track['x'], track['y'])]
        for key in ('trueAddedIllumination', 'remainingAddedIllumination', 'strictRemainingAddedIllumination'):
            row[key] = [v-r for v, r in zip(row[key], retained)]
        row['scoreTarget'] = 'Per-footprint log-luminance blend of source and independently generated clean lighting.'
    for group, metrics in summary.items():
        subset = [r for r in rows if group == 'all' or r['scoreOnlyGroup'] == group]
        for key, label in [('trueAddedIllumination', 'baseline'), ('remainingAddedIllumination', 'corrected'), ('strictRemainingAddedIllumination', 'strictCorrected')]:
            steps = [b-a for r in subset for a, b in zip(r[key], r[key][1:])]
            centred = [v-statistics.mean(r[key]) for r in subset for v in r[key]]
            metrics[label+'StepRMS'] = component.rms(steps)
            metrics[label+'TrackCentredRMS'] = component.rms(centred)
        del metrics['sourceStepRMS'], metrics['sourceTrackCentredRMS']
        metrics['jointValidatedTracks'] = sum(r['gainState'] == 'validated_gain_component' for r in subset)
        metrics['independentEventValidatedTracks'] = sum(r['gainState'] == 'validated_gain_component'
            and r.get('gainEventValidation', {}).get('passed', False)
            and r.get('independentEventValidation', {}).get('passed', False) for r in subset)
        metrics['supportedObservations'] = sum(len(r['frames']) for r in subset if r['gainState'] == 'validated_gain_component')
    return summary, rows


def selftest():
    wave = [0, .4, -.3, 0]*6
    q = [h-v for h, v in zip(component.smooth(wave, 256), wave)]
    # An already correct partial correction, plus unrelated calibration/drift,
    # requests exactly zero. Unsupported private gain is never projected away.
    for strength in (0, .25, .5, 1):
        assert correction(wave, 1.2, strength*1.2, strength, 256) == [0]*len(wave)
    # A source-unaffected foreground removes only an inherited common gain.
    delta = correction(wave, 0, .7, 1, 256)
    intrinsic = [.03*statistics.mean(wave[:i+1]) for i in range(len(wave))]
    private = [.1+.002*i for i in range(len(wave))]
    before = [v+p+.7*r for v, p, r in zip(intrinsic, private, q)]
    after = [v+d for v, d in zip(before, delta)]
    assert max(abs(v-(a+b)) for v, a, b in zip(after, intrinsic, private)) < 1e-12
    assert correction([0]*24, 1, -1, 1, 256) == [0]*24
    # Reproduce the review failure through the actual fitted gain, including
    # the low-frequency part of H(phi) and independent gain calibration.
    sinusoid = [.4*math.sin(2*math.pi*i/24) for i in range(240)]
    q = [h-v for h, v in zip(component.smooth(sinusoid, 256), sinusoid)]
    x = [q[i+1]-q[i] for i in range(96, 144)]
    for strength in (.25, .5, 1):
        y = [strength*1.2*v+.004 for v in x]
        fitted = gain_fit(x, y)
        assert abs(fitted[0]-strength*1.2) < 1e-12 and abs(fitted[1]-.004) < 1e-12
        assert max(map(abs, correction(sinusoid, 1.2, fitted[0], strength, 256))) < 1e-12
    assert correction(wave, 1, .8, 0, 256) == [0]*len(wave)
    return ['already_correct_partial_gain_zero', 'unaffected_surface_preserves_intrinsic_and_private_gain',
            'quiet_component_exact_zero', 'fitted_sinusoidal_correct_gain_with_drift_unchanged', 'zero_strength_exact_zero']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('tracks', 'source', 'baseline', 'clean', 'output'):
        parser.add_argument(name, type=Path)
    parser.add_argument('--strength', type=float, default=1)
    parser.add_argument('--penalty', type=float, default=256)
    parser.add_argument('--minimum-donors', type=int, default=12)
    parser.add_argument('--quiet-floor', type=float, default=.005)
    parser.add_argument('--excitation', type=float, default=.03)
    parser.add_argument('--agreement', type=float, default=.015)
    args = parser.parse_args()
    assert 0 <= args.strength <= 1 and args.penalty >= 0
    assert not args.output.exists()
    tests = selftest()
    original = json.loads(args.tracks.read_text())['tracks']
    tracks = [{k: t[k] for k in ('frames', 'x', 'y', 'sourceLevels')} for t in original]
    source = json.loads(args.source.read_text())
    frozen = component.estimate(tracks, len(source), args)
    frozen_hash = hashlib.sha256(json.dumps(frozen, sort_keys=True).encode()).hexdigest()
    baseline = json.loads(args.baseline.read_text())
    assert len(source) == len(baseline)
    edges = component.source_edges(tracks)
    for row, track in zip(frozen['tracks'], tracks):
        row['sourceRequestedEV'] = row['requestedEV']
        row['requestedEV'] = [0.0]*len(row['frames'])
        row['strictRequestedEV'] = [0.0]*len(row['frames'])
        gain = [component.level(baseline[f], x, y)-component.level(source[f], x, y)
                for f, x, y in zip(track['frames'], track['x'], track['y'])]
        row['baselineGainEV'] = gain
        if row['state'] not in ('supported_response', 'supported_absence'):
            row['gainState'] = 'source_abstention'
            continue
        common, _, _ = component.waveform(edges, len(source), args, row['track'])
        q = [h-v for h, v in zip(component.smooth(common, args.penalty), common)]
        x = [q[b]-q[a] for a, b in zip(row['frames'], row['frames'][1:])]
        raw_y = [b-a for a, b in zip(gain, gain[1:])]
        y = raw_y
        active = [i for i, v in enumerate(row['commonIncrements']) if abs(v) >= args.excitation]
        split = (active[(len(active)-1)//2]+active[len(active)//2])//2+1
        folds = [list(range(split)), list(range(split, len(x)))]
        check = gain_validate(x, y, folds, args)
        episodes = []
        for i in active:
            if not episodes or i > episodes[-1][-1]+1:
                episodes.append([])
            episodes[-1].append(i)
        strict = gain_validate(x, y, episodes, args) if len(episodes) >= 2 else {'passed': False}
        row.update(gainValidation=check, gainEventValidation=strict)
        if not check['passed']:
            row['gainState'] = 'gain_abstention'
            continue
        beta = 0 if check['absence'] else check['coefficient']
        delta = correction(common, row['coefficient'], beta, args.strength, args.penalty)
        row['requestedEV'] = [delta[f] for f in row['frames']]
        row['gainState'] = 'validated_gain_component'
        if strict['passed'] and row['independentEventValidation']['passed']:
            row['strictRequestedEV'] = row['requestedEV']
    # Clean targets appear only after both source and baseline estimates freeze.
    clean = json.loads(args.clean.read_text())
    assert len(clean) == len(source)
    summary, rows = score(frozen, original, source, baseline, clean, args.strength)
    report = {'scope': 'Offline matched-source-footprint gain-component calibration; no render/export.',
              'limitations': ['Same-event temporal folds do not prove independent-event generalization.',
                             'Scalar shared lighting cannot identify arbitrary intrinsic correlated scene changes.',
                             'Unknown/private baseline gain is preserved; full-frame leakage is untested.',
                             'Strength applies to an output produced at that strength; this audit does not synthesize a partial baseline.'],
              'selftests': tests, 'sourceEstimateSHA256BeforeBaselineLoaded': frozen_hash,
              'inputs': {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in (args.tracks, args.source, args.baseline, args.clean, Path(__file__), Path(component.__file__))},
              'parameters': {k: v for k, v in vars(args).items() if not isinstance(v, Path)},
              'summary': summary, 'tracks': rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as out:
        json.dump(report, out, indent=2, allow_nan=False)
        out.write('\n')
    print(json.dumps({'output': str(args.output), 'summary': summary}))


if __name__ == '__main__':
    main()
