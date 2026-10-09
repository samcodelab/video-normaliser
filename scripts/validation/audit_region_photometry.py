"""Compare rectangular and connected-interior photometry on identical held-out pixels."""
import argparse,json,math,statistics
from collections import deque
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('thumbnails',type=Path);p.add_argument('tracking',type=Path);p.add_argument('output',type=Path);p.add_argument('--first-frame',type=int,required=True);p.add_argument('--frame',type=int,required=True);p.add_argument('--rectangle-half',type=int,default=6,choices=[2,6]);p.add_argument('--coordinate-scale',type=int,default=1,choices=[1,2]);a=p.parse_args();assert not a.output.exists()
images=json.loads(a.thumbnails.read_text());tracking=json.loads(a.tracking.read_text())
def sample(im,x,y):
 w,h=im['width'],im['height']
 if not(0<=x<w-1 and 0<=y<h-1):return None
 ix,iy=int(x),int(y);fx,fy=x-ix,y-iy;k=(iy*w+ix)*3;r=im['rgb']
 return [((r[k+c]*(1-fx)+r[k+3+c]*fx)*(1-fy)+(r[k+w*3+c]*(1-fx)+r[k+w*3+3+c]*fx)*fy) for c in range(3)]
def interior(values,erosion=1):
 seed=values.get((0,0))
 if seed is None:return set()
 chroma=lambda v:[math.log2(v[0]/v[1]),math.log2(v[2]/v[1])]
 centre=chroma(seed);eligible={k for k,v in values.items() if max(abs(x-y) for x,y in zip(chroma(v),centre))<.20}
 if (0,0) not in eligible:return set()
 mask={(0,0)};queue=deque(mask)
 while queue:
  x,y=queue.popleft()
  for key in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)]:
   if key in eligible and key not in mask:mask.add(key);queue.append(key)
 for _ in range(erosion):
  mask = {k for k in mask if all(v in mask for v in [(k[0]-1,k[1]),(k[0]+1,k[1]),(k[0],k[1]-1),(k[0],k[1]+1)])}
 return mask
# Mask invariance is algebraic under channel gains, without log floors.
fixture={(x,y):[.08+.001*x,.16+.001*y,.12] for y in range(-6,7) for x in range(-6,7)}
gained={k:[v[c]*2**[.4,-.3,.2][c] for c in range(3)] for k,v in fixture.items()}
assert interior(fixture)==interior(gained) and len(interior(fixture))==121
# Distinct material boundaries must remain separate connected components.
boundary={k:([.08,.20,.10] if k[0]<3 else [.20,.08,.10]) for k in fixture}
shifted={k:([.08,.20,.10] if k[0]<2 else [.20,.08,.10]) for k in fixture}
assert all(x<1 for x,y in interior(boundary)&interior(shifted))
rows=[];source,target=images[a.frame-1],images[a.frame];frame=a.frame-a.first_frame
for index,track in enumerate(tracking['tracks']):
 view={v['frame']:v for v in track['observations']}
 if frame-1 not in view or frame not in view:continue
 before,after=view[frame-1],view[frame];first,second={},{}
 for dy in range(-6*a.coordinate_scale,6*a.coordinate_scale+1):
  for dx in range(-6*a.coordinate_scale,6*a.coordinate_scale+1):
   x=sample(source,(before['x']+before['offsetX']+.5)*a.coordinate_scale-.5+dx,(before['y']+before['offsetY']+.5)*a.coordinate_scale-.5+dy);y=sample(target,(after['x']+after['offsetX']+.5)*a.coordinate_scale-.5+dx,(after['y']+after['offsetY']+.5)*a.coordinate_scale-.5+dy)
   if x and y and all(.003<v<.8 for v in x+y):first[(dx,dy)]=x;second[(dx,dy)]=y
 mask=interior(first,a.coordinate_scale)&interior(second,a.coordinate_scale)
 deltas={k:[math.log2(second[k][c]/first[k][c]) for c in range(3)] for k in first}
 folds=[]
 for parity in [0,1]:
  train=[v for (x,y),v in deltas.items() if int(x>=0)==parity and abs(x)<=a.rectangle_half*a.coordinate_scale and abs(y)<=a.rectangle_half*a.coordinate_scale]
  region=[v for (x,y),v in deltas.items() if (x,y) in mask and int(x>=0)==parity]
  held=[v for (x,y),v in deltas.items() if (x,y) in mask and int(x>=0)!=parity]
  if len(train)<(8 if a.rectangle_half==2 else 20) or min(len(region),len(held))<10:continue
  fullGain=[statistics.mean(v[c] for v in train) for c in range(3)];regionGain=[statistics.mean(v[c] for v in region) for c in range(3)]
  error=lambda gain:math.sqrt(statistics.mean((v[c]-gain[c])**2 for v in held for c in range(3)))
  folds.append({'parity':parity,'rectangleHeldOutRMSEV':error(fullGain),'regionHeldOutRMSEV':error(regionGain),'rectangleChannelEV':fullGain,'regionChannelEV':regionGain,'trainingInteriorPixels':len(region),'heldOutInteriorPixels':len(held)})
 if len(folds)==2:rows.append({'track':index,'sourceFrames':[a.frame-1,a.frame],'position':[after['x'],after['y']],'interiorPixels':len(mask),'folds':folds})
summary={'examinedAdjacentTracks':sum(frame-1 in {v['frame'] for v in t['observations']} and frame in {v['frame'] for v in t['observations']} for t in tracking['tracks']),'comparablePatches':len(rows),'medianRectangleHeldOutRMSEV':statistics.median(statistics.mean(f['rectangleHeldOutRMSEV'] for f in r['folds']) for r in rows) if rows else None,'medianRegionHeldOutRMSEV':statistics.median(statistics.mean(f['regionHeldOutRMSEV'] for f in r['folds']) for r in rows) if rows else None,'bothFoldsImproved':sum(all(f['regionHeldOutRMSEV']<f['rectangleHeldOutRMSEV'] for f in r['folds']) for r in rows)}
report={'syntheticChecks':{'uniformRGBGainMaskInvariant':True,'movingMaterialBoundarySeparated':True},'status':'Diagnostic only; no correction improvement established.','rectangleHalf':a.rectangle_half,'coordinateScale':a.coordinate_scale,'summary':summary,'source':str(a.thumbnails),'tracking':str(a.tracking),'method':'Scaled 13x13 coarse-coordinate footprints (25x25 at 2x); centre mapping (x+.5)*scale-.5; connected seed-relative log-chroma distance below .20 EV, one-pixel erosion; transported source/target mask intersection; RGB means fitted on left/right blocks; both models tested on identical withheld interior pixels.','limitations':'Colour similarity does not prove surface identity. Seed can cross materials. Excluded pixels reduce scope. No clean illumination reference or temporal target quality.','patches':rows};a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(summary,indent=2))
