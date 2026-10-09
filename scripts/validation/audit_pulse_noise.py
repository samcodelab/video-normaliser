"""Calibrate source pulse pixel error on the known-static generated control.

This is an oracle-geometry audit, not a production tracker or a correction score.
The global-static generator holds camera and material geometry fixed; temporal
variation consists of multiplicative exposure plus encoded/resampled error.
"""
import argparse
import hashlib
import json
import math
import statistics
from pathlib import Path


def audit(thumbnails, manifest):
    metadata = json.loads(manifest.read_text())
    assert metadata['frames'] == 72 and metadata['fps'] == 12
    assert any(case['id'] == 'global-static' for case in metadata['cases'])
    assert thumbnails.parent.name == 'global-static', 'Use the known-static diagnostic folder'
    control = manifest.parent/'cases/global-static/input.mov'
    assert control.is_file()
    images = json.loads(thumbnails.read_text())
    assert len(images) == metadata['frames']
    assert all(image['width'] == 96 and image['height'] == 56 for image in images)
    errors = []
    for frame in range(1, len(images)-1):
        for y in range(7, 49, 6):
            for x in range(7, 89, 6):
                residual = []
                for dy in range(-2, 3):
                    for dx in range(-2, 3):
                        position = ((y+dy)*96+x+dx)*3
                        residual.append([
                            math.log2(images[frame]['rgb'][position+c])
                            - 0.5*math.log2(images[frame-1]['rgb'][position+c])
                            - 0.5*math.log2(images[frame+1]['rgb'][position+c])
                            for c in range(3)])
                held_error = 0.0
                pixels = [p for p in range(25) if p % 5 != 2 and p // 5 != 2]
                folds = [[p for p in pixels if p//5 < 2], [p for p in pixels if p//5 > 2],
                         [p for p in pixels if p % 5 < 2], [p for p in pixels if p % 5 > 2]]
                for index, training in enumerate(folds):
                    held = folds[index ^ 1]
                    for channel in range(3):
                        coefficient = statistics.median(residual[p][channel] for p in training)
                        error = math.sqrt(statistics.mean(
                            (residual[p][channel]-coefficient)**2 for p in held))
                        held_error = max(held_error, error)
                errors.append(held_error)
    return {
        'scope': 'Oracle fixed geometry on generated global-static source; no tracker or corrected output',
        'limitation': 'Includes codec, colour conversion and resampling variation; not a sensor noise estimate',
        'thumbnails': str(thumbnails),
        'thumbnailsSha256': hashlib.sha256(thumbnails.read_bytes()).hexdigest(),
        'manifestSha256': hashlib.sha256(manifest.read_bytes()).hexdigest(),
        'sourceControl': str(control),
        'sourceControlSha256': hashlib.sha256(control.read_bytes()).hexdigest(),
        'geometryGeneratorSha256': hashlib.sha256(Path('scripts/validation/BenchmarkAudit.swift').read_bytes()).hexdigest(),
        'patches': len(errors),
        'heldErrorMedianEV': statistics.median(errors),
        'heldErrorP95EV': sorted(errors)[int(0.95*len(errors))],
        'heldRMSOnlyAcceptanceFraction': {
            str(tolerance): sum(error <= tolerance for error in errors)/len(errors)
            for tolerance in [0.02, 0.04, 0.08, 0.12]},
        'note': 'Adjacent pixel folds are internal response checks, not independent material donors.'}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('thumbnails', type=Path)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    assert not args.report.exists(), 'Reports are immutable; choose a new filename'
    args.report.write_text(json.dumps(audit(args.thumbnails, args.manifest), indent=2)+'\n')
