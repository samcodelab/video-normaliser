"""Inspect source-selected patch support at a problematic frame transition.

Diagnostics identify estimator behaviour; they do not establish clean lighting truth.
"""
import argparse
import json
import math
from pathlib import Path
from statistics import median


def inspect(native, region_file, before, after, region):
    cells = json.loads((native/'source-cells.json').read_text())
    fields = json.loads((native/'spatial-fields.json').read_text())
    global_stops = json.loads((native/'global-stops.json').read_text())
    regions = json.loads(region_file.read_text())
    rows = []
    for frame in [before, after]:
        entry = next(x for x in regions if x['frame'] == frame)
        # InspectRegions stores the source-selected patches for the requested region.
        patches = entry['region0Support']
        ids = [x['patch'] for x in patches]
        if not ids or any(min(2,(p//24)*3//14)*4+min(3,(p%24)*4//24) != region for p in ids):
            raise ValueError('Region selection does not match the supplied patch diagnostic')
        confidence = [fields[frame]['confidence'][p] for p in ids]
        rows.append({'frame': frame, 'patches': ids,
                     'medianConfidence': median(confidence),
                     'unsupportedPatchCount': sum(x < 0.02 for x in confidence),
                     'patchCount': len(ids), 'globalEV': global_stops[frame],
                     'sharedEV': fields[frame].get('sharedExposureEV'),
                     'patchEvidence': [{'patch': p, 'sourceLinear': cells[frame][p],
                                        'confidence': fields[frame]['confidence'][p]} for p in ids]})
    common = sorted(set(rows[0]['patches']) & set(rows[1]['patches']))
    if not common:
        raise ValueError('No common source-selected patches; transition is unsupported')
    return {'region': region, 'frames': rows,
            'commonSourceSelectedPatches': common,
            'medianSourceStepEV': median(math.log2(cells[after][p]/cells[before][p]) for p in common),
            'globalStepEV': global_stops[after]-global_stops[before],
            'limitation': 'Brightness changes may include reflectance, geometry and illumination. Confidence is estimator support, not a probability.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('native', type=Path)
    parser.add_argument('regions', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--before', type=int, required=True)
    parser.add_argument('--after', type=int, required=True)
    parser.add_argument('--region', type=int, required=True)
    args = parser.parse_args()
    result = inspect(args.native,args.regions,args.before,args.after,args.region)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:v for k,v in result.items() if k != 'frames'},indent=2))
