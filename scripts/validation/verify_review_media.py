"""Verify real exports using exact packet timestamps and copied audio payloads."""
import argparse
import json
import subprocess
from fractions import Fraction
from pathlib import Path

PROBE = '/Applications/Parallels Toolbox.app/Contents/Frameworks/ToolboxCommon.framework/Versions/A/Resources/ToolboxCommon.bundle/Contents/MacOS/ffmpeg/ffprobe'


def inspect(path):
    return json.loads(subprocess.check_output([PROBE, '-v', 'error', '-show_streams',
        '-show_packets', '-show_format', '-show_data_hash', 'sha256', '-of', 'json', str(path)]))


def compare(source, output):
    documents = [inspect(source), inspect(output)]
    checks = {}
    for kind in ['video', 'audio']:
        tracks = [[s for s in d['streams'] if s['codec_type'] == kind] for d in documents]
        assert len(tracks[0]) == len(tracks[1]), f'{kind} stream count changed'
        assert len(tracks[0]) <= 1, 'Audit expects one stream of each type'
        if not tracks[0]:
            checks[kind] = {'present': False, 'preserved': True}
            continue
        packets = [sorted([p for p in d['packets'] if p['stream_index'] == track[0]['index']],
                   key=lambda p: int(p['pts'])) for d, track in zip(documents, tracks)]
        timelines = [[(Fraction(int(p['pts'])) * Fraction(track[0]['time_base']),
                       Fraction(int(p['duration'])) * Fraction(track[0]['time_base']))
                      for p in group] for group, track in zip(packets, tracks)]
        result = {'present': True, 'packetCounts': [len(p) for p in packets],
                  'exactPresentationTimesMatch': [x[0] for x in timelines[0]] == [x[0] for x in timelines[1]],
                  'exactPacketDurationsMatch': [x[1] for x in timelines[0]] == [x[1] for x in timelines[1]]}
        if kind == 'video' and not result['exactPacketDurationsMatch']:
            # Some MOV edit lists round the presentation end beyond the last
            # packet. With no audio, format duration gives that edit-list end.
            # Accept only an exactly reproduced sub-frame hold, with every
            # preceding packet duration and all frame starts unchanged.
            no_audio = not any(s['codec_type'] == 'audio' for s in documents[0]['streams'])
            source_end = Fraction(documents[0]['format']['duration']) + Fraction(documents[0]['format'].get('start_time', '0'))
            packet_end = sum(timelines[0][-1])
            padding = source_end - packet_end
            hold = (no_audio and len(timelines[0]) == len(timelines[1])
                    and 0 < padding < timelines[0][-1][1]
                    and [x[1] for x in timelines[0][:-1]] == [x[1] for x in timelines[1][:-1]]
                    and sum(timelines[1][-1]) == source_end)
            result['sourceEditPadding'] = str(padding)
            result['finalSamplePreservesSourceEditHold'] = hold
        if kind == 'audio':
            result['encodedPayloadsMatch'] = [p['data_hash'] for p in packets[0]] == [p['data_hash'] for p in packets[1]]
            result['sampleRateAndChannelsMatch'] = all(tracks[0][0].get(k) == tracks[1][0].get(k) for k in ['sample_rate', 'channels'])
        else:
            result['dimensionsMatch'] = all(tracks[0][0][k] == tracks[1][0][k] for k in ['width', 'height'])
        result['preserved'] = (result['exactPresentationTimesMatch']
            and (result['exactPacketDurationsMatch'] or result.get('finalSamplePreservesSourceEditHold', False))
            and all(v for k,v in result.items() if k in ['encodedPayloadsMatch','sampleRateAndChannelsMatch','dimensionsMatch']))
        checks[kind] = result
    return {'source': str(source), 'output': str(output), 'checks': checks,
            'passed': all(c['preserved'] for c in checks.values())}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('report', type=Path)
    args = parser.parse_args()
    result = compare(args.source, args.output)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    assert result['passed'], 'Export integrity changed; inspect report'
