"""Measure audit preview RGBA files from readpng, using fixed screen regions.
Coordinates are top-left normalised image coordinates; frames are zero-based.
"""
import json, pathlib, statistics, sys
boxes = {'upper wall':(.38,.03,.22,.15), 'left wall':(.02,.48,.12,.2),
         'right wall':(.86,.30,.12,.35), 'left floor':(.02,.88,.14,.1),
         'centre floor':(.4,.88,.18,.1), 'right floor':(.84,.88,.14,.1)}
root=pathlib.Path(sys.argv[1]); report={}
for name,(x,y,w,h) in boxes.items():
 report[name]={}
 for mode in ['source','global','corrected']:
  rows=[]
  for i in [12,13,14]:
   a=(root/f'{mode}-{i}.png.rgba').read_bytes(); width=1600; height=len(a)//(width*4)
   pixels=[tuple(a[(yy*width+xx)*4:(yy*width+xx)*4+3]) for yy in range(int(y*height),int((y+h)*height)) for xx in range(int(x*width),int((x+w)*width))]
   luma=sorted(sum(v*k for v,k in zip(p,[.2126,.7152,.0722])) for p in pixels)
   rgb=[statistics.mean(p[c] for p in pixels) for c in range(3)]
   rows.append(dict(frame=i,mean=statistics.mean(luma),p10=luma[int(len(luma)*.1)],p90=luma[int(len(luma)*.9)],rgb=rgb,rg=rgb[0]/rgb[1],bg=rgb[2]/rgb[1],nearWhite=sum(max(p)>=250 for p in pixels)/len(pixels)))
  report[name][mode]=rows
 print(name,[(m,[[round(r[k],1) for k in ['mean','p10','p90']] for r in rows]) for m,rows in report[name].items()])
(root/'measurements.json').write_text(json.dumps(report,indent=2))
