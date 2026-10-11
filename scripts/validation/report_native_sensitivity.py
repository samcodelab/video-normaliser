#!/usr/bin/env python3
"""Compare source-only broad geometry and spatial sensitivity; no correction fit."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('narrow', type=Path)
    parser.add_argument('broad', type=Path)
    parser.add_argument('controls', nargs='+', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--binary', required=True, type=Path)
    args = parser.parse_args()
    narrow, broad = (json.loads(p.read_text()) for p in (args.narrow, args.broad))
    assert narrow['source'] == broad['source']
    assert narrow['geometryThreshold'] == broad['geometryThreshold']
    assert not narrow['broadLandmarkProbe'] and broad['broadLandmarkProbe']
    for report in (narrow, broad):
        boxes = report['nonoverlappingSupportEnvelopes']
        w, h = report['nativeSize']
        assert len(boxes) == len(report['rows'])
        assert all(0 <= b[0] <= b[2] < w and 0 <= b[1] <= b[3] < h for b in boxes)
        assert all(a[2] < b[0] or b[2] < a[0] or a[3] < b[1] or b[3] < a[1]
                   for i, a in enumerate(boxes) for b in boxes[i + 1:])
    old = {(r['analysisX'], r['analysisY']): r for r in narrow['rows']}
    paired = Counter()
    for row in broad['rows']:
        checks = {tuple(c['frames']): c['reason'] for c in old[row['analysisX'], row['analysisY']]['checks']}
        for check in row['checks']:
            paired[checks[tuple(check['frames'])] == 'accepted', check['reason'] == 'accepted'] += 1
    selected = []
    for row in narrow['rows']:
        if (row['analysisX'], row['analysisY']) in ((431, 303), (495, 303)):
            selected.append({'analysisX': row['analysisX'], 'analysisY': row['analysisY'],
                             'frames': [s for s in row['meterSensitivity'] if s['frame'] in (186, 187, 188)]})
    controls = []
    for path in args.controls:
        report = json.loads(path.read_text())
        qualified = [p for r in report['rows'] for p in r['pulses']
                     if p['geometryQualified'] and p.get('rejection') is None]
        controls.append({'report': str(path), 'regions': len(report['rows']),
                         'qualifiedMeasurements': len(qualified),
                         'maximumAbsoluteExcursionEV': max((abs(p['representativeExcursionEV']) for p in qualified), default=None)})
    files = [args.narrow, args.broad, *args.controls, args.binary, Path(__file__),
             Path('scripts/validation/NativeDisjointSupportAudit.swift'), Path(narrow['source'])]
    result = {'pairedGeometry': {'bothAccepted': paired[True, True], 'lost': paired[True, False],
                                'recovered': paired[False, True], 'bothRejected': paired[False, False]},
              'narrowRegions': len(narrow['rows']), 'broadRegions': len(broad['rows']),
              'selectedDiagnosticFootprints': selected, 'controls': controls,
              'sha256': {str(p): digest(p) for p in files},
              'limitation': 'Source-only experiment. Spatial deletion and position sensitivity are not noise confidence intervals or temporal flicker error. Selected printed footprints are diagnostic, not a shipping selection rule. Controls are sparse and do not test correction. No encoded candidate or correction improvement.'}
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write('\n')
    print(json.dumps(result['pairedGeometry'], sort_keys=True))


if __name__ == '__main__':
    main()
