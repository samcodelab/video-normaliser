#!/usr/bin/env python3
"""Compare retained native-radiance candidates without fitting audit residuals."""
import argparse
import hashlib
import html
import json
import math
import statistics
from pathlib import Path


def read(path):
    return json.loads(Path(path).read_text())


def compare(before_path, after_path, first, end):
    before, after = read(before_path), read(after_path)
    assert before['source'] == after['source']
    assert len(before['transitions']) == len(after['transitions'])
    transitions = []
    for a, b in zip(before['transitions'], after['transitions']):
        assert a['frames'] == b['frames']
        aa, bb = a['sourceSelectedMatchedFootprints'], b['sourceSelectedMatchedFootprints']
        assert len(aa) == len(bb)
        for x, y in zip(aa, bb):
            for key in ['x', 'y', 'matchedX', 'matchedY', 'sourceTextureCorrelation', 'sourceLumaStepEV']:
                assert x[key] == y[key], (a['frames'], key)
        if not aa:
            continue
        u, v = [abs(x['outputLumaStepEV']) for x in aa], [abs(x['outputLumaStepEV']) for x in bb]
        transitions.append({'frames': a['frames'], 'footprints': len(aa),
            'beforeMedianEV': statistics.median(u), 'afterMedianEV': statistics.median(v),
            'beforeMaximumEV': max(u), 'afterMaximumEV': max(v),
            'beforeFootprintRMSEV': math.sqrt(statistics.mean(x*x for x in u)),
            'afterFootprintRMSEV': math.sqrt(statistics.mean(x*x for x in v)),
            'maximumIndividualRegressionEV': max(y-x for x, y in zip(u, v)),
            'individualRegressionsOverOneMillistop': sum(y-x > .001 for x, y in zip(u, v))})
    supported = [t for t in transitions if t['footprints'] >= 12]
    interval = [t for t in transitions if first <= t['frames'][0] < end-1]
    def rms(rows, key):
        return math.sqrt(statistics.mean(t[key]**2 for t in rows))
    return {'baselineAudit': str(before_path), 'candidateAudit': str(after_path),
        'baselineVideo': before['corrected'], 'candidateVideo': after['corrected'],
        'sourceSelectionExactlyPreserved': True, 'supportedTransitions': len(supported),
        'beforeRMSOfSupportedTransitionMediansEV': rms(supported, 'beforeMedianEV'),
        'afterRMSOfSupportedTransitionMediansEV': rms(supported, 'afterMedianEV'),
        'beforeIntervalRMSOfTransitionMediansEV': rms(interval, 'beforeMedianEV'),
        'afterIntervalRMSOfTransitionMediansEV': rms(interval, 'afterMedianEV'),
        'interval': interval}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('manifest', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    assert not args.output.exists(), 'Fresh report directory required'
    manifest = read(args.manifest)
    report = {'method': 'Decoded encoded-video luminance on source-selected corresponding 13×13 footprints. Global RMS uses transitions with at least 12 footprints.',
        'limitation': 'Research exports. Regional timing corroboration is not unwanted-lighting truth or a calibrated sensor-noise bound. Individual footprints may regress despite lower aggregate scores. Source guards in the dense candidates overlap the retained phase; phase 7 is a separate encoded spatial check.',
        'cases': [], 'controls': [], 'sha256': {}}
    paths = [args.manifest, Path(__file__)]
    for item in manifest['cases']:
        result = {'name': item['name'], 'status': item['status'],
            'retained': compare(item['baseline'], item['candidate'], item['first'], item['endExclusive'])}
        paths.extend([Path(item['baseline']), Path(item['candidate'])])
        if 'shiftedBaseline' in item:
            result['shifted'] = compare(item['shiftedBaseline'], item['shiftedCandidate'], item['first'], item['endExclusive'])
            paths.extend([Path(item['shiftedBaseline']), Path(item['shiftedCandidate'])])
        media = read(item['media'])
        assert media['passed'], item['name']
        result['media'] = media
        paths.extend([Path(item['media']), Path(result['retained']['candidateVideo'])])
        report['cases'].append(result)
    for item in manifest['controls']:
        evidence = read(item['evidence'])
        counts = {}
        for m in evidence['measurements']:
            row = counts.setdefault(m['event'], {'meters': 0, 'active': 0})
            row['meters'] += 1
            row['active'] += int(m['active'])
        assert all(c['active'] == 0 for c in counts.values()), item['name']
        report['controls'].append({'name': item['name'], 'events': counts, 'limitation': item['limitation']})
        paths.append(Path(item['evidence']))
    for path in paths:
        report['sha256'][str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    args.output.mkdir(parents=True)
    (args.output/'report.json').write_text(json.dumps(report, indent=2)+'\n')
    page = '<!doctype html><meta charset="utf-8"><title>Native regional flicker review</title><style>body{font:16px system-ui;max-width:1100px;margin:40px auto;padding:0 20px}table{border-collapse:collapse;width:100%}td,th{padding:8px;border-bottom:1px solid #ddd;text-align:right}td:first-child,th:first-child{text-align:left}video{max-width:100%;width:520px}small{color:#555}</style><h1>Native regional flicker review</h1>'
    page += '<p>'+html.escape(report['method'])+'</p>'
    for case in report['cases']:
        page += '<h2>'+html.escape(case['name'])+'</h2><p>'+html.escape(case['status'])+'</p>'
        for phase in ['retained', 'shifted']:
            if phase not in case:
                continue
            result = case[phase]
            page += '<h3>'+html.escape(phase)+' encoded footprints</h3><table><tr><th>Frames</th><th>Count</th><th>Median before</th><th>Median after</th><th>Maximum before</th><th>Maximum after</th></tr>'
            for t in result['interval']:
                page += '<tr><td>'+str(t['frames'])+'</td><td>'+str(t['footprints'])+'</td>'+''.join(f'<td>{t[k]:.5f}</td>' for k in ['beforeMedianEV','afterMedianEV','beforeMaximumEV','afterMaximumEV'])+'</tr>'
            page += '</table>'
    page += '<h2>Negative source controls</h2>'
    for c in report['controls']:
        counts = list(c['events'].values())
        page += '<p>'+html.escape(c['name'])+f': {min(x["meters"] for x in counts)}–{max(x["meters"] for x in counts)} meters per event; zero activations. <small>'+html.escape(c['limitation'])+'</small></p>'
    page += '<p>'+html.escape(report['limitation'])+'</p><p><a href="report.json">Full measurements, individual regressions and hashes</a></p>'
    (args.output/'index.html').write_text(page)
    print('REPORT', args.output)


if __name__ == '__main__':
    main()
