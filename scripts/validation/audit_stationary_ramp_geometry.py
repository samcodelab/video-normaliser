#!/usr/bin/env python3
"""Inspect a known stationary synthetic background rejected by native geometry.

Ground-truth masks certify this control only. They never select production donors.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path


def decode_mask(runs, size):
    mask = []
    foreground = False
    for run in runs:
        if not isinstance(run, int) or run < 0 or len(mask)+run > size:
            raise ValueError('Invalid ground-truth mask')
        mask.extend([foreground]*run)
        foreground = not foreground
    if len(mask) != size:
        raise ValueError('Incomplete ground-truth mask')
    return mask


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('clean_report', type=Path)
    parser.add_argument('ramp_report', type=Path)
    parser.add_argument('ramp_masks', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--last-frame', type=int, default=33, choices=[32, 33])
    args = parser.parse_args()
    clean, ramp = [json.loads(p.read_text()) for p in (args.clean_report, args.ramp_report)]
    assert clean['nativeSize'] == ramp['nativeSize'] == [320, 192]
    assert all(r['luminanceGeometryProbe'] for r in (clean, ramp))
    assert Path(clean['source']).parent.name == 'no-flicker-motion'
    assert Path(ramp['source']).parent.name == 'intentional-ramp'
    assert Path(ramp['source']).name == 'target.mov'
    masks = json.loads(args.ramp_masks.read_text())
    assert len(masks) == 72
    chosen = []
    for report in (clean, ramp):
        index = next(i for i, r in enumerate(report['rows']) if (r['analysisX'], r['analysisY']) == (39, 39))
        chosen.append((report['rows'][index], report['nonoverlappingSupportEnvelopes'][index]))
    assert chosen[0][1] == chosen[1][1]
    bounds = chosen[1][1]
    # A stronger full-height column check avoids relying on vertical orientation
    # conventions. The moving foreground never enters even these columns.
    columns = range(math.floor(bounds[0]), math.ceil(bounds[2])+1)
    assert all(0 <= x < 320 for x in columns)
    for frame in range(28, args.last_frame+1):
        mask = decode_mask(masks[frame], 320*192)
        assert not any(mask[y*320+x] for y in range(192) for x in columns)
    comparisons = []
    for frame in range(28, args.last_frame):
        checks = [next(c for c in row['checks'] if c['frames'] == [frame, frame+1]) for row, _ in chosen]
        assert all(c['refinementPixels'] == [0, 0] for c in checks)
        comparisons.append({'frames': [frame, frame+1], 'cleanScore': checks[0]['geometryScore'],
                            'rampScore': checks[1]['geometryScore'], 'rampRejection': checks[1]['reason']})
    files = [args.clean_report, args.ramp_report, args.ramp_masks, Path(__file__),
             Path('scripts/validation/BenchmarkAudit.swift'), Path(clean['source']), Path(ramp['source'])]
    result = {'seed': [39, 39], 'supportEnvelope': bounds,
              'framesWithNoForegroundInEntireSupportColumns': list(range(28, args.last_frame+1)),
              'comparisons': comparisons, 'sha256': {str(p): digest(p) for p in files},
              'limitation': 'Known synthetic stationary background and neutral intended ramp from BenchmarkAudit construction. Full native support columns are outside ground-truth foreground. Geometry failure here is a false rejection under the native encoded/decoded appearance change. This does not isolate quantization, compression or colour-transfer causes, calibrate LEGO sensor noise, or authorize lowering a threshold. Masks are diagnostic control truth, not donor selection.'}
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write('\n')
    print(json.dumps(comparisons))


if __name__ == '__main__':
    main()
