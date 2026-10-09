"""Serial encoded settings sweep; never equate weaker correction with a failure."""
import argparse
import json
import subprocess
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROFILES = {
    'default': {},
    'off': {'strength': 0},
    'half-strength': {'strength': 0.5},
    'half-spatial': {'spatial-strength': 0.5},
    'global-only': {'spatial-strength': 0},
    'half-colour': {'colour-strength': 0.5},
    'brightness-only': {'colour-strength': 0},
    'short-radius': {'radius': 0.2},
    'long-radius': {'radius': 1.5},
    'balanced': {'strength': 0.75, 'spatial-strength': 0.5, 'colour-strength': 0.5},
}
STEADY = ['default', 'off', 'half-strength', 'half-spatial', 'balanced']


def run(suite, revision, source_runner=None):
    dataset = ROOT/'dist/Benchmarks'/('adversarial-v30' if suite == 'adversarial' else f'motion-v2-{suite}')
    runner = ROOT/f'.build/slider-range-{revision}-{suite}-runner'
    runner.mkdir(parents=True, exist_ok=False)
    source_runner = source_runner or ROOT/'.build/benchmark'
    for filename in ['audit', 'build-provenance.json']:
        shutil.copy2(source_runner/filename, runner/filename)
    cases = json.loads((dataset/'manifest.json').read_text())['cases']
    for mode in ['smooth', 'steady']:
        for name, values in PROFILES.items():
            if mode == 'steady' and name not in STEADY:
                continue
            label = f'slider-range-{revision}-{mode}-{name}'
            folder = dataset/'results'/label
            command = [str(runner/'audit'), 'run', str(dataset), '--label', label, '--mode', mode]
            for key, value in values.items():
                command += ['--'+key, str(value)]
            print('START', suite, mode, name, flush=True)
            log = ROOT/f'.build/{suite}-{label}.log'
            with log.open('w') as stream:
                subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True, cwd=ROOT)
            scores = json.loads((folder/'scores.json').read_text())
            assert {x['id'] for x in scores} == {x['id'] for x in cases}
            assert all(x['timingAndGeometryPreserved'] for x in scores)
            (folder/'sweep-profile.json').write_text(json.dumps({'name': name, 'mode': mode, 'parameters': values, 'command': command},indent=2)+'\n')
            print('COMPLETE', suite, mode, name, len(scores), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--suite', choices=['development','holdout','adversarial'], required=True)
    parser.add_argument('--revision', default='v29')
    parser.add_argument('--runner', type=Path, help='Immutable runner directory; defaults to the latest benchmark build')
    arguments = parser.parse_args()
    if not arguments.revision or '/' in arguments.revision or arguments.revision in ['.', '..']:
        parser.error('revision must be a single output-label component')
    run(arguments.suite, arguments.revision, arguments.runner)
