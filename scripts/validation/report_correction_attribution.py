"""Rank fixed-cell temporal events; never label source changes as known flicker."""
import argparse
import hashlib
import json
import math
from pathlib import Path
from statistics import median


def summarize(report, cuts):
    frames = report['frames']
    events = []
    brightness = []
    for frame in frames:
        cells = frame['cells']
        if len(cells) != 336:
            raise ValueError('Expected 24×14 cells')
        for cell in cells:
            if not all(math.isfinite(v) for v in cell.values()):
                raise ValueError('Nonfinite diagnostic')
            if abs(cell['globalGainEV'] + cell['localContributionEV'] +
                   cell['anchorContributionEV'] - cell['totalGainEV']) > 1e-10:
                raise ValueError('Attribution does not telescope')
        brightness.append({'frame': frame['frame'], 'medianAppliedGainEV': median(c['totalGainEV'] for c in cells),
                           'maximumCellGainEV': max(c['totalGainEV'] for c in cells)})
    for before, after in zip(frames, frames[1:]):
        if after['frame'] != before['frame'] + 1:
            raise ValueError('Noncontiguous frames')
        if after['frame'] in cuts:
            continue
        rows = []
        for p, (a, b) in enumerate(zip(before['cells'], after['cells'])):
            delta = {k: b[k] - a[k] for k in ['sourceEV', 'globalGainEV', 'localContributionEV',
                                             'anchorContributionEV', 'totalGainEV', 'outputEV']}
            rows.append({'cell': p, 'column': p % 24, 'row': p // 24, **delta,
                         'minimumEstimatorConfidence': min(a['estimatorConfidence'], b['estimatorConfidence'])})
        events.append({'before': before['frame'], 'after': after['frame'],
                       'medianAbsoluteOutputStepEV': median(abs(c['outputEV']) for c in rows),
                       'maximumAbsoluteOutputStepEV': max(abs(c['outputEV']) for c in rows),
                       'medianSignedSourceStepEV': median(c['sourceEV'] for c in rows),
                       'medianSignedGainStepEV': median(c['totalGainEV'] for c in rows),
                       'worstCells': sorted(rows, key=lambda c: abs(c['outputEV']), reverse=True)[:12]})
    return {'limitation': report['limitation'], 'cutsExcluded': sorted(cuts),
            'events': sorted(events, key=lambda e: e['medianAbsoluteOutputStepEV'], reverse=True),
            'highestGainFrames': sorted(brightness, key=lambda f: f['medianAppliedGainEV'], reverse=True)[:20],
            'interpretation': 'High gain is not proof of overcorrection. Fixed-cell events include motion. Inspect source and output together; stage contributions are ordered counterfactuals.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--cuts', required=True, help='Comma-separated zero-based scene start frames; use empty string for none')
    args = parser.parse_args()
    result = summarize(json.loads(args.input.read_text()), {int(x) for x in args.cuts.split(',') if x})
    result['inputSHA256'] = hashlib.sha256(args.input.read_bytes()).hexdigest()
    with args.output.open('x') as handle:
        json.dump(result, handle, indent=2)
        handle.write('\n')
    print(json.dumps({'topEvents': [{k:v for k,v in e.items() if k != 'worstCells'} for e in result['events'][:8]],
                      'highestGainFrames': result['highestGainFrames'][:3]}, indent=2))
