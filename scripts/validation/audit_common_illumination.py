#!/usr/bin/env python3
"""Offline source-only common illumination component experiment.

No renderer, native code, or movie is changed. Estimation receives stripped source
trajectories only. Clean thumbnails and oracle categories are loaded after all
estimates are frozen. A reciprocal temporal-block check is distinguished from the
stronger check that withholds complete illumination episodes. Neither establishes
that a temporally correlated scene change is lighting in arbitrary footage.
"""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path


def rms(values):
    return math.sqrt(sum(v*v for v in values)/len(values)) if values else None


def med(values):
    return statistics.median(values) if values else 0.0


def smooth(values, penalty):
    """Natural-end second-difference smoothing; banded LDL solve, O(n)."""
    n = len(values)
    diagonal = [1.0]*n
    first = [0.0]*n
    second = [0.0]*n
    for i in range(n-2):
        diagonal[i] += penalty
        diagonal[i+1] += 4*penalty
        diagonal[i+2] += penalty
        first[i+1] -= 2*penalty
        first[i+2] -= 2*penalty
        second[i+2] += penalty
    d, l1, l2 = [0.0]*n, [0.0]*n, [0.0]*n
    for i in range(n):
        if i >= 2:
            l2[i] = second[i]/d[i-2]
        if i >= 1:
            l1[i] = (first[i] - (l2[i]*d[i-2]*l1[i-1] if i >= 2 else 0))/d[i-1]
        d[i] = diagonal[i] - (l1[i]**2*d[i-1] if i >= 1 else 0) - (l2[i]**2*d[i-2] if i >= 2 else 0)
    y = [0.0]*n
    for i in range(n):
        y[i] = values[i] - (l1[i]*y[i-1] if i >= 1 else 0) - (l2[i]*y[i-2] if i >= 2 else 0)
    x = [v/dd for v, dd in zip(y, d)]
    for i in reversed(range(n)):
        x[i] -= (l1[i+1]*x[i+1] if i+1 < n else 0) + (l2[i+2]*x[i+2] if i+2 < n else 0)
    return x


def independent(a, b):
    # Disjoint 5x5 samples at both ends, not just distinct tracking IDs.
    return all(max(abs(a[k]-b[k]), abs(a[k+1]-b[k+1])) >= 5 for k in (0, 2))


def source_edges(tracks):
    edges = {}
    for identifier, t in enumerate(tracks):
        for j in range(1, len(t['frames'])):
            frame = t['frames'][j]
            if frame != t['frames'][j-1]+1:
                continue
            edges.setdefault(frame, []).append({
                'track': identifier,
                'footprint': (t['x'][j-1], t['y'][j-1], t['x'][j], t['y'][j]),
                'change': t['sourceLevels'][j]-t['sourceLevels'][j-1]})
    return edges


def waveform(edges, count, args, query=None):
    increments, support = [0.0]*count, [None]*count
    for frame, observations in edges.items():
        own = next((p for p in observations if p['track'] == query), None)
        chosen = []
        # Fixed source-geometric ordering. Median does not weight track longevity.
        for p in sorted(observations, key=lambda p: (p['footprint'][2], p['footprint'][3], p['track'])):
            if p['track'] == query or (own and not independent(p['footprint'], own['footprint'])):
                continue
            if all(independent(p['footprint'], q['footprint']) for q in chosen):
                chosen.append(p)
        if len(chosen) < args.minimum_donors:
            continue
        half = len(chosen)//2
        left, right = [med([p['change'] for p in part]) for part in (chosen[:half], chosen[half:])]
        value = med([p['change'] for p in chosen])
        quiet = max(abs(left), abs(right), abs(value)) <= args.quiet_floor
        # Independent halves must agree on direction, not amplitude: a common
        # light can have very different coupling on opposite sides of the shot.
        # Amplitude and repeatability are tested in each held-out track response.
        coherent = quiet or (left*right > 0 and min(abs(left), abs(right)) > args.quiet_floor)
        if not coherent:
            continue
        # Keep small increments in an excited shot: zeroing each quiet edge
        # separately would turn a legitimate smooth drift into a staircase.
        increments[frame] = value
        support[frame] = {'donors': len(chosen), 'left': left, 'right': right,
                          'quiet': quiet, 'spatialDifference': abs(left-right)}
    levels = [0.0]
    for value in increments[1:]:
        levels.append(levels[-1]+value)
    return levels, increments, support


def coefficient(x, y):
    """Robust through-origin response after source-only slow drift removal."""
    weights = [1.0]*len(x)
    beta = 0.0
    for _ in range(5):
        den = sum(w*v*v for w, v in zip(weights, x))
        if den < 1e-12:
            return None
        beta = sum(w*a*b for w, a, b in zip(weights, x, y))/den
        residual = [b-beta*a for a, b in zip(x, y)]
        scale = max(.001, 1.4826*med([abs(v-med(residual)) for v in residual]))
        weights = [min(1.0, 3*scale/max(1e-12, abs(v))) for v in residual]
    return beta


def validate(x, y, folds, args):
    models, errors, null_errors = [], [], []
    for held in folds:
        train = [i for i in range(len(x)) if i not in held]
        if not any(abs(x[i]) >= args.excitation for i in train) or not any(abs(x[i]) >= args.excitation for i in held):
            return {'passed': False, 'reason': 'unexcited_temporal_fold'}
        beta = coefficient([x[i] for i in train], [y[i] for i in train])
        if beta is None:
            return {'passed': False, 'reason': 'singular_response'}
        models.append(beta)
        errors.extend(y[i]-beta*x[i] for i in held)
        null_errors.extend(y[i] for i in held)
    beta = coefficient(x, y)
    error, null = rms(errors), rms(null_errors)
    bounded = abs(beta) <= 2.5
    consistent = max(models)-min(models) <= max(.06, .15*abs(beta))
    absence = abs(beta) <= .03 and max(map(abs, models)) <= .05 and null <= .01 and max(map(abs, y)) <= .025
    explained = error <= max(args.agreement, .06*null) and error <= .7*null
    passed = bounded and consistent and (absence or explained)
    return {'passed': passed, 'reason': 'supported_absence' if passed and absence else 'validated_response' if passed else 'response_validation_failed',
            'coefficient': beta, 'foldCoefficients': models, 'heldErrorRMS': error,
            'heldNullRMS': null, 'consistent': consistent, 'bounded': bounded,
            'absence': absence}


def estimate(tracks, count, args):
    """Only source coordinates/levels are visible inside this function."""
    edges = source_edges(tracks)
    common, increments, support = waveform(edges, count, args)
    # An unknown edge is never silently treated as a measured zero increment:
    # reject integrated correction across this shot if any edge lacks support.
    full_support = all(support[1:])
    quiet = full_support and max(map(abs, increments)) <= args.quiet_floor
    outputs = []
    for identifier, track in enumerate(tracks):
        frames = track['frames']
        result = {'track': identifier, 'frames': frames, 'requestedEV': [0.0]*len(frames),
                  'strictRequestedEV': [0.0]*len(frames), 'state': 'unknown'}
        if quiet:
            result.update(state='quiet_common_component', coefficient=0.0)
            outputs.append(result)
            continue
        local, dx, evidence = waveform(edges, count, args, identifier)
        if not all(evidence[1:]) or any(b != a+1 for a, b in zip(frames, frames[1:])):
            result['reason'] = 'unsupported_integrated_waveform'
            outputs.append(result)
            continue
        raw_x = [dx[f] for f in frames[1:]]
        common_drift = med([v for v in raw_x if abs(v) <= args.quiet_floor])
        x = [v-common_drift for v in raw_x]
        raw_y = [b-a for a, b in zip(track['sourceLevels'], track['sourceLevels'][1:])]
        quiet_y = [v for v, u in zip(raw_y, x) if abs(u) <= args.quiet_floor]
        drift = med(quiet_y)
        y = [v-drift for v in raw_y]
        active = [i for i, v in enumerate(x) if abs(v) >= args.excitation]
        if len(active) < 2:
            result['reason'] = 'insufficient_source_excitation'
            outputs.append(result)
            continue
        split = (active[(len(active)-1)//2] + active[len(active)//2])//2 + 1
        folds = [list(range(split)), list(range(split, len(x)))]
        blocked = validate(x, y, folds, args)
        # Separate episodes have at least one unexcited edge between them.
        episodes = []
        for i in active:
            if not episodes or i > episodes[-1][-1]+1:
                episodes.append([])
            episodes[-1].append(i)
        independent_event = validate(x, y, episodes, args) if len(episodes) >= 2 else {'passed': False, 'reason': 'only_one_excitation_episode'}
        result.update(temporalValidation=blocked, independentEventValidation=independent_event,
                      excitationEdges=len(active), excitationEpisodes=len(episodes), sourceDriftPerFrame=drift,
                      commonDriftPerFrame=common_drift,
                      sourceIncrements=raw_y, commonIncrements=x)
        if blocked['passed']:
            beta = 0.0 if blocked['absence'] else blocked['coefficient']
            filtered = smooth(local, args.penalty)
            requested = [args.strength*beta*(filtered[f]-local[f]) for f in frames]
            result.update(state='supported_absence' if blocked['absence'] else 'supported_response',
                          coefficient=beta, requestedEV=requested)
            if independent_event['passed']:
                result['strictRequestedEV'] = requested
        else:
            result['reason'] = blocked['reason']
        outputs.append(result)
    return {'commonLevels': common, 'commonIncrements': increments, 'commonSupport': support,
            'quiet': quiet, 'fullCommonSupport': full_support, 'tracks': outputs}


def level(image, x, y):
    width, rgb = image['width'], image['rgb']
    total = sum(sum(rgb[((y+dy)*width+x+dx)*3+c]*weight for c, weight in enumerate((.2126, .7152, .0722)))
                for dy in range(-2, 3) for dx in range(-2, 3))/25
    return math.log2(max(1e-9, total))


def score(frozen, original, source, clean):
    rows = []
    for result, track in zip(frozen['tracks'], original):
        group = 'crossing' if track['occupancyChanges'] else 'foreground' if track['initialForegroundPixels'] == 25 else 'background' if track['initialForegroundPixels'] == 0 else 'mixed'
        added = [level(source[f], x, y)-level(clean[f], x, y) for f, x, y in zip(track['frames'], track['x'], track['y'])]
        corrected = [v+r for v, r in zip(added, result['requestedEV'])]
        strict = [v+r for v, r in zip(added, result['strictRequestedEV'])]
        rows.append(dict(result, scoreOnlyGroup=group, trueAddedIllumination=added,
                         remainingAddedIllumination=corrected, strictRemainingAddedIllumination=strict))
    summary = {}
    for group in ('all', 'foreground', 'background', 'mixed', 'crossing'):
        subset = [p for p in rows if group == 'all' or p['scoreOnlyGroup'] == group]
        metrics = {'tracks': len(subset), 'observations': sum(len(p['frames']) for p in subset),
                   'states': {state: sum(p['state'] == state for p in subset) for state in ('quiet_common_component', 'supported_absence', 'supported_response', 'unknown')},
                   'independentEventValidatedTracks': sum(p.get('independentEventValidation', {}).get('passed', False) and p['state'] != 'unknown' for p in subset)}
        for key, label in [('trueAddedIllumination', 'source'), ('remainingAddedIllumination', 'corrected'), ('strictRemainingAddedIllumination', 'strictCorrected')]:
            steps = [b-a for p in subset for a, b in zip(p[key], p[key][1:])]
            centred = [v-statistics.mean(p[key]) for p in subset for v in p[key]]
            metrics[label+'StepRMS'] = rms(steps)
            metrics[label+'TrackCentredRMS'] = rms(centred)
        requested = [v for p in subset for v in p['requestedEV']]
        metrics['requestedEVRMS'] = rms(requested)
        metrics['requestedEVMax'] = max(map(abs, requested), default=0)
        metrics['supportedObservations'] = sum(len(p['frames']) for p in subset if p['state'] in ('supported_response', 'supported_absence'))
        metrics['unknownReasons'] = {reason: sum(p.get('reason') == reason for p in subset)
                                     for reason in sorted({p['reason'] for p in subset if 'reason' in p})}
        summary[group] = metrics
    return summary, rows


def selftest(args):
    assert max(abs(v-w) for v, w in zip(smooth([1+2*i for i in range(20)], 256), [1+2*i for i in range(20)])) < 1e-9
    assert smooth([0.0]*20, 256) == [0.0]*20
    x = [.4, -.7, .3, 0, .4, -.7, .3, 0]
    folds = [list(range(4)), list(range(4, 8))]
    assert validate(x, [1.2*v for v in x], folds, args)['passed']
    assert validate(x, [0.0]*8, folds, args)['absence']
    assert not validate(x, [v*(1 if i < 4 else -.5) for i, v in enumerate(x)], folds, args)['passed']
    synthetic = []
    for j in range(28):
        synthetic.append({'frames': list(range(16)), 'x': [5+(j % 7)*10]*16,
                          'y': [5+(j//7)*10]*16,
                          'sourceLevels': [float(j)+(.02*math.sin(i) if j < 4 else 0) for i in range(16)]})
    quiet = estimate(synthetic, 16, args)
    assert quiet['quiet'] and all(v == 0 for p in quiet['tracks'] for v in p['requestedEV'])
    wave = [([0, .4, -.3, 0][i % 4]) for i in range(16)]
    for j, t in enumerate(synthetic):
        t['sourceLevels'] = [j + v + .001*i for i, v in enumerate(wave)]
    lit = estimate(synthetic, 16, args)
    expected = [args.strength*(h-v) for h, v in zip(smooth(wave, args.penalty), wave)]
    assert all(p['state'] == 'supported_response' for p in lit['tracks'])
    assert max(abs(a-b) for p in lit['tracks'] for a, b in zip(p['requestedEV'], expected)) < 1e-9
    independent_before = waveform(source_edges(synthetic), 16, args, 0)
    synthetic[0]['sourceLevels'] = [100*math.cos(i) for i in range(16)]
    independent_after = waveform(source_edges(synthetic), 16, args, 0)
    assert independent_before == independent_after
    return ['natural_ends_preserve_affine_trend', 'zero_waveform_exact_zero', 'known_linear_response',
            'supported_absence', 'reject_inconsistent_response', 'quiet_intrinsic_motion_exact_zero',
            'end_to_end_component_target_preserves_intrinsic_linear_drift', 'query_cannot_fit_its_own_waveform']


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tracks', type=Path)
    parser.add_argument('source', type=Path)
    parser.add_argument('clean', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--strength', type=float, default=1.0)
    parser.add_argument('--penalty', type=float, default=256.0, help='Second-difference smoothing lambda; frame units, not seconds.')
    parser.add_argument('--minimum-donors', type=int, default=12)
    parser.add_argument('--quiet-floor', type=float, default=.005)
    parser.add_argument('--excitation', type=float, default=.03)
    parser.add_argument('--agreement', type=float, default=.015)
    args = parser.parse_args()
    assert 0 <= args.strength <= 1 and args.penalty >= 0
    assert not args.output.exists(), 'Use a new immutable report path'
    tests = selftest(args)
    original = json.loads(args.tracks.read_text())['tracks']
    tracks = [{k: t[k] for k in ('frames', 'x', 'y', 'sourceLevels')} for t in original]
    source = json.loads(args.source.read_text())
    # No clean thumbnail or oracle category is passed to estimate().
    frozen = estimate(tracks, len(source), args)
    estimate_hash = hashlib.sha256(json.dumps(frozen, sort_keys=True).encode()).hexdigest()
    clean = json.loads(args.clean.read_text())
    assert len(source) == len(clean)
    summary, rows = score(frozen, original, source, clean)
    parameters = {k: v for k, v in vars(args).items() if not isinstance(v, Path)}
    report = {'scope': 'Source-only common illumination component; offline matched-footprint targets, no spatial rendering or baseline calibration.',
              'limitations': ['Temporal-block validation can use opposite sides of the same pulse. Strict results additionally withhold entire excitation episodes.',
                              'A common correlated intrinsic scene change can mimic illumination. These three clips do not establish generalization.',
                              'Sparse trajectories: scores weight matched observations and do not measure full-frame coverage or transitions between fitted tracks.',
                              'One scalar waveform cannot represent multiple independently changing lights or channel-dependent responses.',
                              'Natural-end smoothing uses frame units; production must use actual timestamps and scene boundaries.',
                              'Unknown integrated edges abstain for the whole shot; no unsupported increments are silently interpolated.'],
              'parameters': parameters, 'selftests': tests, 'estimateSHA256BeforeCleanLoaded': estimate_hash,
              'inputs': {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (args.tracks, args.source, args.clean, Path(__file__))},
              'summary': summary, 'quiet': frozen['quiet'], 'fullCommonSupport': frozen['fullCommonSupport'],
              'commonLevels': frozen['commonLevels'], 'commonIncrements': frozen['commonIncrements'],
              'commonSupport': frozen['commonSupport'], 'tracks': rows}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('x') as output:
        json.dump(report, output, indent=2, allow_nan=False)
        output.write('\n')
    print(json.dumps({'output': str(args.output), 'summary': summary}))


if __name__ == '__main__':
    main()
