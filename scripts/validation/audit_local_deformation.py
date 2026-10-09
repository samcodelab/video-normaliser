"""Held-out local similarity geometry at frozen accepted track centres.
No corrected pixels, target illumination or rendering are produced.
"""
import argparse,json,math,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('thumbnails',type=Path);p.add_argument('tracking',type=Path);p.add_argument('output',type=Path);p.add_argument('--first-frame',type=int,required=True);p.add_argument('--frame',type=int,required=True);args=p.parse_args()
assert not args.output.exists()
images=json.loads(args.thumbnails.read_text());tracking=json.loads(args.tracking.read_text())
def sample(im,x,y):
 w,h=im['width'],im['height']
 if not(0<=x<w-1 and 0<=y<h-1):return None
 ix,iy=int(x),int(y);fx,fy=x-ix,y-iy;k=(iy*w+ix)*3;r=im['rgb']
 return [((r[k+c]*(1-fx)+r[k+3+c]*fx)*(1-fy)+(r[k+w*3+c]*(1-fx)+r[k+w*3+3+c]*fx)*fy) for c in range(3)]
def fit(points,parity):
 train=[v for v in points if v[0]==parity];held=[v for v in points if v[0]!=parity]
 if min(len(train),len(held))<30:return None
 gains=[statistics.mean(v[1][c] for v in train) for c in range(3)]
 if max(map(abs,gains))>2:return None
 loss=lambda group:statistics.mean((v[1][c]-gains[c])**2 for v in group for c in range(3))
 return {'trainingMSE':loss(train),'heldOutRMSEV':math.sqrt(loss(held)), 'channelEV':gains,'pixels':len(points)}
rows=[];a,b=images[args.frame-1],images[args.frame]
for index,track in enumerate(tracking['tracks']):
 view={v['frame']:v for v in track['observations']};f=args.frame-args.first_frame
 if f-1 not in view or f not in view:continue
 source,target=view[f-1],view[f];ax=source['x']+source['offsetX'];ay=source['y']+source['offsetY'];bx=target['x']+target['offsetX'];by=target['y']+target['offsetY']
 candidates=[]
 for scale in [.90,.95,1,1.05,1.10]:
  for angle in [-6,-3,0,3,6]:
   co,si=math.cos(math.radians(angle)),math.sin(math.radians(angle));points=[]
   for dy in range(-6,7):
    for dx in range(-6,7):
     x=sample(a,ax+dx,ay+dy);y=sample(b,bx+scale*(co*dx-si*dy),by+scale*(si*dx+co*dy))
     if x is None or y is None or not all(.003<v<.8 for v in x+y):continue
     points.append((int(dx>=0),[math.log2(y[c]/x[c]) for c in range(3)]))
   candidates.append({'scale':scale,'rotationDegrees':angle,'points':points})
 # Use identical valid pixels for every candidate to prevent support selection.
 # The sample identity must be retained explicitly for this intersection.
 # Restrict this initial diagnostic to fully supported footprints.
 candidates=[c for c in candidates if len(c['points'])==169]
 if not candidates:continue
 fixed=next((c for c in candidates if c['scale']==1 and c['rotationDegrees']==0),None)
 if fixed is None:continue
 folds=[]
 for parity in [0,1]:
  baseline=fit(fixed['points'],parity)
  fitted=[(c,fit(c['points'],parity)) for c in candidates];fitted=[(c,v) for c,v in fitted if v is not None]
  if baseline is None or not fitted:continue
  chosen,model=min(fitted,key=lambda cv:cv[1]['trainingMSE'])
  folds.append({'parity':parity,'baseline':baseline,'selected':model,'scale':chosen['scale'],'rotationDegrees':chosen['rotationDegrees']})
 if len(folds)==2:rows.append({'track':index,'sourceFrames':[args.frame-1,args.frame],'position':[target['x'],target['y']],'folds':folds})
summary={'completeFootprints':len(rows),'medianBaselineHeldOutRMSEV':statistics.median(statistics.mean(f['baseline']['heldOutRMSEV'] for f in r['folds']) for r in rows) if rows else None,'medianSelectedHeldOutRMSEV':statistics.median(statistics.mean(f['selected']['heldOutRMSEV'] for f in r['folds']) for r in rows) if rows else None,'bothFoldsImproved':sum(all(f['selected']['heldOutRMSEV']<f['baseline']['heldOutRMSEV'] for f in r['folds']) for r in rows)}
report={'status':'Diagnostic only; no correction improvement established.','summary':summary,'source':str(args.thumbnails),'tracking':str(args.tracking),'models':{'scales':[.90,.95,1,1.05,1.10],'rotationDegrees':[-6,-3,0,3,6]},'validation':'Geometry selected on one half-patch, photometric prediction scored on the other; reversed folds. All candidates use complete 169-pixel RGB footprints.','limitations':'Source-selected centres and correlated pixels; resampling can soften texture. Similarity fit does not prove physical identity or safe temporal correction. Clipped/dark footprints excluded.','patches':rows}
args.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(summary,indent=2))
