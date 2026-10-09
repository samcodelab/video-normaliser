"""Summarize isolated native correspondence diagnostics, without tuning gates."""
import argparse
import collections
import json
from pathlib import Path


def reason(details):
    if details.get('sourceEnergy', -1) <= .018:
        return 'weakSourceTexture'
    if 'forwardConfidence' not in details:
        return 'noForwardCandidate'
    if details['forwardConfidence'] <= .3:
        return 'lowForwardConfidence'
    if 'reverseConfidence' not in details:
        return 'noReverseCandidate'
    if details['reverseConfidence'] <= .3:
        return 'lowReverseConfidence'
    if abs(details['reverseDX']) > 1 or abs(details['reverseDY']) > 1:
        return 'reverseDisagreement'
    return 'other'


parser = argparse.ArgumentParser()
parser.add_argument('input', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
source = json.loads(args.input.read_text())
frames = []
for frame in sorted({a['frame'] for a in source['attempts']}):
    attempts = [a for a in source['attempts'] if a['frame'] == frame]
    failed = [a for a in attempts if a['outcome'] == 'noMatch']
    counts = collections.Counter(reason(a['details'][0]) for a in failed)
    frames.append({'frame': frame, 'outcomes': dict(collections.Counter(a['outcome'] for a in attempts)),
                   'localFailureReasons': dict(counts)})
report = {'input': str(args.input), 'frames': frames,
          'limitations': 'Local search reasons; guided searches, when available, remain in the raw report. '
          'A rejected match is not proof that a real corresponding surface exists.'}
args.output.write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(frames, indent=2))
