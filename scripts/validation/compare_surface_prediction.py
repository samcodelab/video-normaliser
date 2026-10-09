"""Compare thumbnail gain predictions with decoded, source-matched output.

This diagnoses model/render disagreement; it is not a quality acceptance gate.
"""
import argparse
import json
import math
import statistics
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('before', type=Path)
parser.add_argument('after', type=Path)
parser.add_argument('before_matched', type=Path)
parser.add_argument('after_matched', type=Path)
parser.add_argument('first', type=int)
parser.add_argument('report', type=Path)
parser.add_argument('--full-render', type=Path, help='Uncompressed FullResolutionPredictionAudit report')
args = parser.parse_args()

def read(folder, name):
    return json.loads((folder / name).read_text())

def render(image, field, global_ev):
    surface = field['surface']
    w, h = image['width'], image['height']
    mw, mh = surface['width'], surface['height']
    output = []
    for y in range(h):
        for x in range(w):
            rgb = image['rgb'][(y*w+x)*3:(y*w+x)*3+3]
            xx = max(0, min(mw-1, (x+.5)/w*mw-.5))
            yy = max(0, min(mh-1, (y+.5)/h*mh-.5))
            ix, iy = min(mw-2, int(xx)), min(mh-2, int(yy))
            fx, fy = xx-ix, yy-iy
            nodes = [(iy*mw+ix, (1-fx)*(1-fy)), (iy*mw+ix+1, fx*(1-fy)),
                     ((iy+1)*mw+ix, (1-fx)*fy), ((iy+1)*mw+ix+1, fx*fy)]
            weights = [(n, weight*max(.0001, math.exp(-sum(
                math.log2(max(.003, rgb[c])/max(.003, surface['guide'][n*3+c]))**2
                for c in range(3))/.3))) for n, weight in nodes]
            total = sum(weight for _, weight in weights)
            corrected = [rgb[c]*2**max(-2, min(2, global_ev+field.get('brightnessEV', 0)+sum(
                surface['channelEV'][n*3+c]*weight/total for n, weight in weights))) for c in range(3)]
            peak, original = max(corrected), max(rgb)
            if peak > .995 and peak > original:
                corrected = [v*max(.995, original)/peak for v in corrected]
            output.extend(corrected)
    return dict(width=w, height=h, rgb=output)

def light(image, x, y):
    w, h = image['width'], image['height']
    ix, iy = int(x), int(y)
    fx, fy = x-ix, y-iy
    value = 0
    for dy in range(-6, 7):
        for dx in range(-6, 7):
            for c, weight in enumerate([.2126, .7152, .0722]):
                def at(xx, yy):
                    return image['rgb'][(min(h-1, yy)*w+min(w-1, xx))*3+c]
                top = at(ix+dx, iy+dy)*(1-fx)+at(ix+dx+1, iy+dy)*fx
                bottom = at(ix+dx, iy+dy+1)*(1-fx)+at(ix+dx+1, iy+dy+1)*fx
                value += weight*max(0, top*(1-fy)+bottom*fy)/169
    return max(.000001, value)

pair = [args.first, args.first+1]
transitions = [next(t for t in json.loads(p.read_text())['transitions'] if t['frames'] == pair)
               for p in [args.before_matched, args.after_matched]]
coordinates = lambda t: [(p['x'], p['y'], p['matchedX'], p['matchedY'])
                          for p in t['sourceSelectedMatchedFootprints']]
assert coordinates(transitions[0]) == coordinates(transitions[1])
images = read(args.after, 'thumbnails.json')
rows = []
native = json.loads(args.full_render.read_text()) if args.full_render else None
if native:
    assert native['frames'] == pair
for folder, transition in zip([args.before, args.after], transitions):
    fields, stops = read(folder, 'spatial-fields.json'), read(folder, 'global-stops.json')
    rendered = [render(images[i], fields[i], stops[i]) for i in pair]
    predicted = [math.log2(light(rendered[1], qx, qy)/light(rendered[0], x, y))
                 for x, y, qx, qy in coordinates(transition)]
    encoded = [p['outputLumaStepEV'] for p in transition['sourceSelectedMatchedFootprints']]
    row = dict(folder=str(folder), predictedMedianAbsoluteStepEV=statistics.median(map(abs, predicted)),
               encodedMedianAbsoluteStepEV=statistics.median(map(abs, encoded)),
               medianAbsolutePredictionErrorEV=statistics.median(abs(a-b) for a, b in zip(predicted, encoded)))
    if native:
        actual = native['beforeThumbnails' if folder == args.before else 'afterThumbnails']
        full = [math.log2(light(actual[1], qx, qy)/light(actual[0], x, y))
                for x, y, qx, qy in coordinates(transition)]
        row['fullResolutionMedianAbsoluteStepEV'] = statistics.median(map(abs, full))
        row['medianAbsoluteThumbnailToFullRenderErrorEV'] = statistics.median(abs(a-b) for a, b in zip(predicted, full))
        row['medianAbsoluteFullRenderToEncodedErrorEV'] = statistics.median(abs(a-b) for a, b in zip(full, encoded))
        quantized = native.get('beforeBGRAThumbnails' if folder == args.before else 'afterBGRAThumbnails')
        if quantized:
            bgra = [math.log2(light(quantized[1], qx, qy)/light(quantized[0], x, y))
                    for x, y, qx, qy in coordinates(transition)]
            row['bgraMedianAbsoluteStepEV'] = statistics.median(map(abs, bgra))
            row['medianAbsoluteFullRenderToBGRAErrorEV'] = statistics.median(abs(a-b) for a, b in zip(full, bgra))
            row['medianAbsoluteBGRAToEncodedErrorEV'] = statistics.median(abs(a-b) for a, b in zip(bgra, encoded))
    rows.append(row)
report = dict(frames=pair, supportedFootprints=len(coordinates(transitions[0])), comparisons=rows,
              limitation='Thumbnail guidance follows downsampling; native export applies guidance before downsampling. Codec differences are also included.')
args.report.write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps(report, indent=2))
