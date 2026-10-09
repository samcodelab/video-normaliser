"""Serial native export/visual-review baseline for local footage; no clean-reference claims."""
import argparse
import hashlib
import html
import json
import re
import os
import shutil
import subprocess
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def run(output, ids):
    manifest = json.loads((REPO / 'scripts/validation/benchmark-real-cases.json').read_text())
    selected = [c for c in manifest['cases'] if not ids or c['id'] in ids]
    if ids and set(ids) != {c['id'] for c in selected}:
        raise ValueError('Unknown real case')
    native = REPO / '.build/benchmark/real-audit'
    if not native.is_file():
        raise FileNotFoundError('Build with zsh scripts/build-benchmark-audit.sh first')
    output.mkdir(parents=True, exist_ok=False)
    results, rows = [], []
    provenance = json.loads((native.parent / 'real-build-provenance.json').read_text())
    if provenance['binarySha256'] != digest(native):
        raise ValueError('Native binary/provenance mismatch; rebuild the benchmark')
    provenance['pipelineOptions'] = {name: os.environ.get(variable) != '0' for name, variable in [
        ('surfacePipeline', 'FRANKLUMA_SURFACE_PIPELINE'), ('surfaceTracking', 'FRANKLUMA_SURFACE_TRACKING'),
        ('channelLighting', 'FRANKLUMA_SURFACE_COLOUR'), ('rowLighting', 'FRANKLUMA_SURFACE_ROWS')]}
    runner = output / 'runner'
    runner.mkdir()
    shutil.copy2(native, runner / 'real-audit')
    (runner / 'real-build-provenance.json').write_text(json.dumps(provenance, indent=2)+'\n')
    # Keep attribution beside the corrected derivatives and review sheets.
    (output / 'attribution.txt').write_text((REPO / 'PracticeFootage/README.md').read_text())
    for case in selected:
        source = Path(case['source'])
        if not source.is_absolute():
            source = REPO / source
        if not source.is_file():
            results.append({**case, 'status': 'missing-local-source'})
            continue
        folder = output / case['id']
        folder.mkdir()
        command = [str(native), str(source), str(folder), '--export', '--review-frames',
                   ','.join(str(i) for i in case['reviewFrames'])]
        with (folder / 'audit.log').open('w') as log:
            subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, cwd=REPO)
        log = (folder / 'audit.log').read_text()
        count = re.search(r'EXPORT VERIFIED (\d+) frames', log)
        cuts = re.search(r'BOUNDARIES (\[[^\]]*\])', log)
        detected = json.loads(cuts[1]) if cuts else None
        integrity = bool(count and int(count[1]) == case['expectedFrames'])
        entry = {**case, 'sourceSha256': digest(source), 'status': 'review-required',
                 'expectedFrameCountPreserved': integrity, 'detectedCuts': detected,
                 'reviewedCutsMatch': detected == case['reviewedCuts'] if case['reviewedCuts'] is not None else None,
                 'qualityScores': None}
        if not integrity:
            raise RuntimeError(f'Frame integrity failed: {case["id"]}')
        results.append(entry)
        rows.append(f'<tr><td>{html.escape(case["id"])}</td><td>{html.escape(case["category"])}</td>'
                    f'<td>{html.escape(str(detected))}</td><td>{html.escape(str(case["reviewFrames"]))}</td>'
                    f'<td><a href="{case["id"]}/comparison.png">Frames</a> · '
                    f'<a href="{case["id"]}/corrected.mp4">Export</a></td></tr>')
        (output / 'inventory.json').write_text(json.dumps({'provenance': provenance, 'cases': results}, indent=2)+'\n')
        print('REVIEW READY', case['id'], flush=True)
    (output / 'inventory.json').write_text(json.dumps({'provenance': provenance, 'cases': results}, indent=2)+'\n')
    (output / 'report.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8"><title>Real footage benchmark</title>
<style>body{font:15px system-ui;margin:32px;max-width:1400px}td,th{padding:10px;text-align:left;border-bottom:1px solid #ddd}p{max-width:1000px;line-height:1.5}</style>
<h1>Real footage review baseline</h1><p>These clips have no verified clean target. Export integrity and scene boundaries can be checked;
brightness diagnostics are descriptive and do not establish correction accuracy. Subject brightness, edge artifacts, local shadows and colour must be reviewed visually.
No foreground/background ground-truth scores or commercial-tool comparisons are claimed.</p>
<p>Sheets show <b>source left, corrected right</b>, at the zero-based frames listed below, in row order.
Review each row and its adjacent rows, then play the export. Rights and source fingerprints are in <a href="inventory.json">inventory.json</a>;
keep <a href="attribution.txt">attribution</a> with third-party derivatives.</p>
<table><tr><th>Clip</th><th>Coverage</th><th>Detected cuts</th><th>Review frames</th><th>Artifacts</th></tr>'''+''.join(rows)+'</table></html>')
    print(output / 'report.html')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    parser.add_argument('--case', action='append', default=[])
    args = parser.parse_args()
    run(args.output.resolve(), args.case)
