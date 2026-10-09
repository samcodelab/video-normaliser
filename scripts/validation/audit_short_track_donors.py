"""Inspect real temporal agreement without changing production correction.

Input is the isolated native TrackingEvidenceAudit dump. Comparisons use actual
RGB EV derivatives; no clean-lighting ground truth is implied by agreement.
"""
import argparse
import json
import math
import statistics
from pathlib import Path


def bucket(track):
    rgb = [2 ** statistics.median(o['channelLevels'][c] for o in track) for c in range(3)]
    total = sum(rgb)
    return int(rgb[0] / total * 6) * 7 + int(rgb[1] / total * 6)


def agreement(a, b):
    shared = sorted(set(a) & set(b))
    pairs = [(i, j) for i, j in zip(shared, shared[1:]) if j == i + 1]
    if len(shared) < 4 or len(pairs) < 3:
        return None
    first = [[a[j]['channelLevels'][c] - a[i]['channelLevels'][c] for i, j in pairs] for c in range(3)]
    second = [[b[j]['channelLevels'][c] - b[i]['channelLevels'][c] for i, j in pairs] for c in range(3)]
    active = sum(v * v for channel in first for v in channel) / (3 * len(pairs)) > .0004
    channels = []
    for x, y in zip(first, second):
        energy = sum(v * v for v in x)
        error = statistics.mean(abs(u - v) for u, v in zip(x, y))
        if energy / len(pairs) <= .0004:
            slope = None
            accepted = sum(v * v for v in y) / len(pairs) < .0004
        else:
            slope = sum(u * v for u, v in zip(x, y)) / energy
            accepted = .85 <= slope <= 1.15 and error < .025
        channels.append({'slope': slope, 'meanAbsoluteDerivativeErrorEV': error, 'accepted': accepted})
    return {'active': active, 'channels': channels, 'accepted': active and all(c['accepted'] for c in channels)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    source = json.loads(args.input.read_text())
    tracks = source['tracks']
    donors = [t for t in tracks if len(t['observations']) >= 8
              and statistics.mean(o['confidence'] for o in t['observations']) >= .65
              and all(max(o['channelLevels']) < math.log2(.8) for o in t['observations'])]
    summaries = []
    for track in tracks:
        observations = track['observations']
        if not 4 <= len(observations) < 8 or statistics.mean(o['confidence'] for o in observations) < .65:
            continue
        lookup = {o['frame']: o for o in observations}
        comparisons = []
        for donor in donors:
            other = donor['observations']
            result = agreement(lookup, {o['frame']: o for o in other})
            if result is None:
                continue
            comparisons.append({'donor': donor['index'], 'sameColourBucket': bucket(observations) == bucket(other), **result})
        summaries.append({'track': track['index'], 'start': observations[0]['frame'],
                          'length': len(observations), 'colourBucket': bucket(observations),
                          'hasJointTarget': track['hasJointTarget'], 'comparisons': comparisons})
    report = {'input': str(args.input), 'eligibleLongDonors': len(donors), 'shortTracks': summaries,
              'limitations': 'Temporal agreement is diagnostic evidence, not proof of common illumination. '
              'Saved observations omit sourcePeakLevel; donor screening uses mean channel levels and may '
              'include donors rejected by production peak clipping checks. This report does not simulate '
              'production joint targets or establish an output improvement.'}
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print('Long donors:', len(donors), 'short tracks:', len(summaries))
    for same in (True, False):
        accepted = sum(any(c['accepted'] and c['sameColourBucket'] == same for c in t['comparisons']) for t in summaries)
        print('Tracks with accepted', 'same-material' if same else 'cross-material', 'donor:', accepted)


if __name__ == '__main__':
    main()
