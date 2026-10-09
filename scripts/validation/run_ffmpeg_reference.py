"""Independent FFmpeg deflicker reference; intentionally not a commercial-tool claim."""
import argparse
import hashlib
import json
import subprocess
from pathlib import Path


def run(root, output, executable):
    manifest = json.loads((root / 'manifest.json').read_text())
    output.mkdir(parents=True, exist_ok=False)
    version = subprocess.check_output([str(executable), '-version'], text=True)
    commands = []
    for case in manifest['cases']:
        folder = output / case['id']
        folder.mkdir()
        for source, target, filters in [('input.mov', 'corrected.mp4', ['-vf', 'deflicker=size=13:mode=median']),
                                        ('target.mov', 'target-noop.mp4', [])]:
            command = [str(executable), '-hide_banner', '-loglevel', 'error', '-i',
                       str(root / 'cases' / case['id'] / source), *filters,
                       '-an', '-c:v', 'libx264', '-crf', '18', '-pix_fmt', 'yuv420p',
                       '-fps_mode', 'passthrough', str(folder / target)]
            subprocess.run(command, check=True)
            commands.append(command)
        print('EXTERNAL EXPORT', case['id'], flush=True)
    (output / 'reference-provenance.json').write_text(json.dumps({
        'engine': 'FFmpeg deflicker', 'version': version,
        'binarySha256': hashlib.sha256(executable.read_bytes()).hexdigest(),
        'filter': 'deflicker=size=13:mode=median', 'commands': commands,
        'limitations': 'One documented configuration, not a tuning search or a proprietary tool comparison. '
                       'No scene segmentation; both corrected and codec-floor clips use the same x264 settings.'
    }, indent=2)+'\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('executable', type=Path)
    args = parser.parse_args()
    run(args.root.resolve(), args.output.resolve(), args.executable.resolve())
