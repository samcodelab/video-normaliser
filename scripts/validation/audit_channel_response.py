"""Check global log-affine channel response using frozen source-only footprints."""
import argparse,json,math,statistics
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('thumbnails',type=Path);p.add_argument('matched',type=Path);p.add_argument('output',type=Path);p.add_argument('--frame',type=int,required=True);a=p.parse_args();assert not a.output.exists()
images=json.loads(a.thumbnails.read_text());matched=json.loads(a.matched.read_text());transition=next(t for t in matched['transitions'] if t['frames']==[a.frame-1,a.frame]);source,target=images[a.frame-1],images[a.frame]
def mean(im,x,y):
 w,h=im['width'],im['height'];out=[0.0]*3
 for dy in range(-6,7):
  for dx in range(-6,7):
   xx=x+dx;yy=y+dy;ix,iy=int(xx),int(yy);fx,fy=xx-ix,yy-iy
   if not(0<=ix<w-1 and 0<=iy<h-1):return None
   k=(iy*w+ix)*3;r=im['rgb']
   for c in range(3):out[c]+=((r[k+c]*(1-fx)+r[k+3+c]*fx)*(1-fy)+(r[k+w*3+c]*(1-fx)+r[k+w*3+3+c]*fx)*fy)/169
 return [math.log2(v) for v in out] if min(out)>.003 and max(out)<.8 else None
points=[]
for v in transition['sourceSelectedMatchedFootprints']:
 x,y=mean(source,v['x'],v['y']),mean(target,v['matchedX'],v['matchedY'])
 if x and y:points.append({'position':[v['x'],v['y']],'source':x,'target':y})
rows=[]
for channel in range(3):
 folds=[]
 for side in [False,True]:
  train=[v for v in points if (v['position'][0]>=source['width']/2)==side];held=[v for v in points if (v['position'][0]>=source['width']/2)!=side]
  if min(len(train),len(held))<6:continue
  x=[v['source'][channel] for v in train];y=[v['target'][channel] for v in train];mx,my=statistics.mean(x),statistics.mean(y);variance=sum((v-mx)**2 for v in x)
  if variance<.1:continue
  slope=sum((u-mx)*(v-my) for u,v in zip(x,y))/variance;offset=my-slope*mx;gain=statistics.mean(v-u for u,v in zip(x,y))
  errors=lambda beta,alpha:[v['target'][channel]-beta*v['source'][channel]-alpha for v in held]
  error=lambda beta,alpha:math.sqrt(statistics.mean(e*e for e in errors(beta,alpha)))
  folds.append({'trainingSide':side,'trainingFootprints':len(train),'heldOutFootprints':len(held),'gainEV':gain,'responseSlope':slope,'responseOffset':offset,'gainHeldOutRMSEV':error(1,gain),'responseHeldOutRMSEV':error(slope,offset),'bounded':.75<=slope<=1.25 and abs(offset)<=2})
 rows.append({'channel':channel,'folds':folds})
materialRows=[]
groups={}
for v in points:
 key=(math.floor((v['source'][0]-v['source'][1])/1),math.floor((v['source'][2]-v['source'][1])/1))
 groups.setdefault(key,[]).append(v)
for key,held in groups.items():
 if len(held)<6:continue
 train=[v for v in points if v not in held]
 if len(train)<12:continue
 for channel in range(3):
  x=[v['source'][channel] for v in train];y=[v['target'][channel] for v in train];mx,my=statistics.mean(x),statistics.mean(y);variance=sum((v-mx)**2 for v in x)
  if variance<.1:continue
  beta=sum((u-mx)*(v-my) for u,v in zip(x,y))/variance;alpha=my-beta*mx;gain=statistics.mean(v-u for u,v in zip(x,y))
  error=lambda b,g:math.sqrt(statistics.mean((v['target'][channel]-b*v['source'][channel]-g)**2 for v in held))
  materialRows.append({'sourceChromaBin':key,'channel':channel,'heldOutFootprints':len(held),'responseSlope':beta,'gainHeldOutRMSEV':error(1,gain),'responseHeldOutRMSEV':error(beta,alpha)})

report={'heldOutMaterialBins':materialRows,'status':'Diagnostic only; no rendering or safe temporal response target established.','source':str(a.thumbnails),'matched':str(a.matched),'sourceFrames':[a.frame-1,a.frame],'footprints':len(points),'validation':'Global per-channel gain versus log-affine response; train on one spatial half and test on the other, reversed. Same source-selected footprints for both models.','limitations':'Footprints overlap and material-specific lights can resemble camera response; no clean illumination reference.','channels':rows};a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(materialRows,indent=2))
