"""Inspect residual-ranked footprints against source-only rejected/accepted evidence.

This is a diagnosis report, never a donor-selection or correction algorithm.
"""
import argparse
import html
import json
from pathlib import Path


def report(matched, diagnostic, frames, limit):
    transition = next(t for t in matched['transitions'] if t['frames'] == frames)
    scale = diagnostic['analysisWidth'] / 96
    evidence = diagnostic['diagnosticRows']
    selected = sorted(transition['sourceSelectedMatchedFootprints'],
                      key=lambda p: abs(p['outputLumaStepEV']), reverse=True)[:limit]
    rows = []
    for patch in selected:
        # Locate the event end of the matched footprint, not its previous-frame seed.
        x, y = patch['matchedX'] * scale, patch['matchedY'] * scale
        nearest = min(evidence, key=lambda r: (r['analysisX']-x)**2 + (r['analysisY']-y)**2)
        distance = ((nearest['analysisX']-x)**2 + (nearest['analysisY']-y)**2)**0.5
        rows.append({'matchedFootprint': patch, 'nearestSourceProbe': nearest if distance <= 8 else None,
                     'probeDistanceAnalysisPixels': distance,
                     'sameSupport': False})
    return {'frames': frames, 'diagnosticEvent': diagnostic['event'], 'rows': rows,
            'limitation': 'Residual ranking is for inspection only. Nearest probes have different physical supports and may overlap; proximity is not proof of correspondence or independent lighting evidence. Source changes may include motion, reflections, clipping and intended illumination. No correction is authorized by this report.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('matched', type=Path)
    parser.add_argument('diagnostic', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--frames', nargs=2, type=int, required=True)
    parser.add_argument('--limit', type=int, default=12)
    args = parser.parse_args()
    matched = json.loads(args.matched.read_text())
    diagnostic = json.loads(args.diagnostic.read_text())
    if diagnostic['event'] != args.frames[1] or matched['source'] != diagnostic['source']:
        parser.error('Source and event must match the selected transition')
    if args.limit < 1 or not diagnostic['diagnosticRows']:
        parser.error('Positive limit and nonempty diagnostic evidence required')
    if args.output.exists():
        parser.error('Use a fresh output directory')
    result = report(matched, diagnostic, args.frames, args.limit)
    args.output.mkdir(parents=True)
    (args.output/'report.json').write_text(json.dumps(result, indent=2)+'\n')
    tables = []
    for row in result['rows']:
        patch, probe = row['matchedFootprint'], row['nearestSourceProbe']
        if probe is None:
            tables.append(f"<h2>Footprint {patch['x']}, {patch['y']}</h2><p>Outside nearby diagnostic support. Encoded step {patch['outputLumaStepEV']:.4f} EV; no local source evidence assigned.</p>")
            continue
        history = probe.get('history', [])
        rejections = {k:v for k,v in probe.items() if 'rejection' in k.lower()}
        if 'eventNeighborChecks' in probe:
            rejections['eventNeighborChecks'] = probe['eventNeighborChecks']
        values = ''.join(f"<tr><td>{h['frame']}</td><td>{h['meanY']:.5f}</td><td>{h['p10Y']:.5f}</td><td>{h['p90Y']:.5f}</td><td>{h['minimumRGB']:.5f}</td><td>{h['maximumRGB']:.5f}</td><td>{h['confidence']:.3f}</td></tr>" for h in history)
        tables.append(f"<h2>Footprint {patch['x']}, {patch['y']}</h2><p>Source step {patch['sourceLumaStepEV']:.4f} EV; encoded step {patch['outputLumaStepEV']:.4f} EV. Nearest probe distance {row['probeDistanceAnalysisPixels']:.2f} analysis pixels; different support.</p><pre>{html.escape(json.dumps(rejections, indent=2))}</pre><table><tr><th>Frame</th><th>Mean Y</th><th>P10 Y</th><th>P90 Y</th><th>Min RGB</th><th>Max RGB</th><th>Geometry confidence</th></tr>{values}</table>")
    (args.output/'report.html').write_text('<!doctype html><meta charset="utf-8"><title>Source footprint diagnosis</title><style>body{font:15px system-ui;max-width:1100px;margin:32px auto}td,th{padding:8px;border-bottom:1px solid #ddd}p{line-height:1.6}</style><h1>Source footprint diagnosis</h1><p>'+html.escape(result['limitation'])+'</p>'+''.join(tables))
    print(f"Wrote {len(result['rows'])} diagnostic footprint reviews to {args.output}")


if __name__ == '__main__':
    main()
