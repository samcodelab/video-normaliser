#!/usr/bin/env python3
"""Measure exact-coordinate continuity in frozen source-selected matches.

This deliberately does not snap a transported patch to a different grid centre.
It establishes a conservative support lower bound, not physical surface identity
or an export-quality measurement. Input output-photometry is never used to link.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def descriptor(image, x, y, mode='log'):
    ix, iy = math.floor(x), math.floor(y)
    fx, fy = x-ix, y-iy
    w, h, rgb = image['width'], image['height'], image['rgb']
    if ix < 6 or iy < 6 or ix+7 >= w or iy+7 >= h:
        return None
    channels = [[], [], []]
    for dy in range(-6, 7):
        for dx in range(-6, 7):
            for c in range(3):
                p = ((iy+dy)*w+ix+dx)*3+c
                value = ((rgb[p]*(1-fx)+rgb[p+3]*fx)*(1-fy)
                         +(rgb[p+w*3]*(1-fx)+rgb[p+w*3+3]*fx)*fy)
                channels[c].append(math.log2(max(.001, value)) if mode.startswith('log') else value)
    values = []
    for channel in channels:
        mean = sum(channel)/len(channel)
        centred = [v-mean for v in channel]
        if mode == 'log-plane':
            # Orthogonal least-squares projection onto constant/x/y lighting.
            # This is identity evidence only, never an exposure correction.
            coordinates = [(dx, dy) for dy in range(-6, 7) for dx in range(-6, 7)]
            sx = sum(v*x for v, (x, _) in zip(centred, coordinates))/2366
            sy = sum(v*y for v, (_, y) in zip(centred, coordinates))/2366
            centred = [v-sx*x-sy*y for v, (x, y) in zip(centred, coordinates)]
        if mode == 'linear-channel':
            channel_norm = math.sqrt(sum(v*v for v in centred))
            if channel_norm <= 1e-8:
                return None
            centred = [v/channel_norm for v in centred]
        values.extend(centred)
    norm = math.sqrt(sum(v*v for v in values))
    return [v/norm for v in values] if norm > 0 else None


def audit(path, thumbnail_path=None, mode='log'):
    data = json.loads(path.read_text())
    thumbnails = json.loads(thumbnail_path.read_text()) if thumbnail_path else None
    active = {}
    completed = []
    transitions = []
    previous_end = None
    identity_breaks = 0
    for pair in sorted(data['transitions'], key=lambda p: p['frames']):
        start, end = pair['frames']
        if previous_end != start:
            completed.extend(active.values())
            active = {}
        following = {}
        continued = 0
        # Reject ambiguous repeated endpoints rather than selecting a donor.
        matches = pair['sourceSelectedMatchedFootprints']
        counts = {}
        source_counts = {}
        for match in matches:
            target = (match['matchedX'], match['matchedY'])
            counts[target] = counts.get(target, 0) + 1
            source = (match['x'], match['y'])
            source_counts[source] = source_counts.get(source, 0) + 1
        consumed = set()
        for match in matches:
            source = (match['x'], match['y'])
            target = (match['matchedX'], match['matchedY'])
            if counts[target] != 1 or source_counts[source] != 1:
                continue
            consumed.add(source)
            history = active.get(source)
            target_descriptor = descriptor(thumbnails[end], *target, mode) if thumbnails else None
            if thumbnails and history is not None:
                anchor = history['_anchor']
                agreement = sum(a*b for a, b in zip(anchor, target_descriptor)) if target_descriptor else -1
                if agreement <= .95:
                    completed.append(history)
                    history = None
                    identity_breaks += 1
            if history is None:
                anchor = descriptor(thumbnails[start], *source, mode) if thumbnails else None
                if thumbnails and (anchor is None or target_descriptor is None
                                   or sum(a*b for a, b in zip(anchor, target_descriptor)) <= .95):
                    continue
                history = {'start': start, 'end': end, 'edges': 1,
                           'minimumCorrelation': match['sourceTextureCorrelation'], '_anchor': anchor}
            else:
                history = dict(history)
                history['end'] = end
                history['edges'] += 1
                history['minimumCorrelation'] = min(
                    history['minimumCorrelation'], match['sourceTextureCorrelation'])
                continued += 1
            following[target] = history
        completed.extend(value for key, value in active.items() if key not in consumed)
        active = following
        transitions.append({'frames': [start, end], 'matches': len(matches),
                            'continuedExactly': continued,
                            'supportAtLeastFourFrames': sum(
                                h['edges'] >= 3 for h in active.values()),
                            'supportAtLeastEightFrames': sum(
                                h['edges'] >= 7 for h in active.values())})
        previous_end = end
    completed.extend(active.values())
    return {'input': str(path.resolve()),
            'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
            'selection': 'Exact source endpoint coordinates only; no output-dependent linking',
            'limitations': ['Fractional camera endpoints may not equal the next sampling grid.',
                           'Pairwise texture agreement does not prove persistent physical identity.',
                           'No spatial basis, correction or perceptual improvement is implemented.'],
            'episodes': len(completed),
            'anchoredIdentityBreaks': identity_breaks,
            'thumbnailInput': str(thumbnail_path.resolve()) if thumbnail_path else None,
            'identityCheck': ('Episode-start source descriptor correlation > 0.95'
                              if thumbnails else 'Pairwise match evidence only'),
            'descriptorMode': mode,
            'thumbnailSHA256': hashlib.sha256(thumbnail_path.read_bytes()).hexdigest() if thumbnail_path else None,
            'maximumEpisodeFrames': max((h['edges'] + 1 for h in completed), default=0),
            'transitions': transitions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports', type=Path, nargs='+')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--thumbnails', type=Path,
                        help='Source thumbnails; requires exactly one match report')
    parser.add_argument('--descriptor', choices=['log', 'linear-channel', 'log-plane'], default='log')
    args = parser.parse_args()
    if args.thumbnails and len(args.reports) != 1:
        parser.error('--thumbnails requires one report')
    result = {'reports': [audit(p, args.thumbnails, args.descriptor) for p in args.reports]}
    # Never replace an earlier benchmark artifact.
    with args.output.open('x') as output:
        json.dump(result, output, indent=2)
        output.write('\n')


if __name__ == '__main__':
    main()
