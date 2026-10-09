"""Whole connected-material photometry with spatially held-out validation.
Fixed source seeds; no corrected images or correction targets are consulted.
"""
import argparse,json,math,statistics
from collections import deque
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('thumbnails',type=Path);p.add_argument('output',type=Path);p.add_argument('--frame',type=int,required=True);p.add_argument('--scale',type=int,default=1,choices=[1,2]);a=p.parse_args();assert not a.output.exists()
images=json.loads(a.thumbnails.read_text());before,after=images[a.frame-1],images[a.frame];w,h=before['width'],before['height'];assert (w,h)==(after['width'],after['height'])
def values(im):
 out=[]
 for i in range(w*h):
  rgb=im['rgb'][i*3:i*3+3]
  out.append([math.log2(v) for v in rgb] if all(.003<v<.8 for v in rgb) else None)
 return out
first,second=values(before),values(after)
def component(values,seed):
 if values[seed] is None:return set()
 centre=[values[seed][0]-values[seed][1],values[seed][2]-values[seed][1]]
 eligible={i for i,v in enumerate(values) if v is not None and max(abs(v[0]-v[1]-centre[0]),abs(v[2]-v[1]-centre[1]))<.20}
 mask={seed};queue=deque(mask)
 while queue:
  i=queue.popleft()
  for j in [i-1,i+1,i-w,i+w]:
   if 0<=j<w*h and abs(j%w-i%w)+abs(j//w-i//w)==1 and j in eligible and j not in mask:mask.add(j);queue.append(j)
 return mask
def plane(train,held,seed):
 parameters=[]
 for c in range(3):
  matrix=[[0.0]*4 for _ in range(3)]
  for i in train:
   basis=[1,i%w-seed%w,i//w-seed//w];target=second[i][c]-first[i][c]
   for j in range(3):
    for k in range(3):matrix[j][k]+=basis[j]*basis[k]
    matrix[j][3]+=basis[j]*target
  for j in range(3):
   pivot=max(range(j,3),key=lambda k:abs(matrix[k][j]));matrix[j],matrix[pivot]=matrix[pivot],matrix[j]
   if abs(matrix[j][j])<1e-9:return None
   denominator=matrix[j][j];matrix[j]=[v/denominator for v in matrix[j]]
   for k in range(3):
    if k!=j:
     factor=matrix[k][j];matrix[k]=[a-factor*b for a,b in zip(matrix[k],matrix[j])]
  parameters.append([matrix[j][3] for j in range(3)])
 errors=[second[i][c]-first[i][c]-sum(v*b for v,b in zip(parameters[c],[1,i%w-seed%w,i//w-seed//w])) for i in held for c in range(3)]
 return {'parameters':parameters,'heldOutRMSEV':math.sqrt(statistics.mean(v*v for v in errors)),'heldOutMedianAbsoluteEV':statistics.median(map(abs,errors))}

rows=[];occupied=set()
for y in range(6*a.scale,h-6*a.scale,8*a.scale):
 for x in range(6*a.scale,w-6*a.scale,8*a.scale):
  seed=y*w+x
  if seed in occupied:continue
  one,two=component(first,seed),component(second,seed);overlap=one&two;union=one|two
  if not union or len(overlap)/len(union)<.75:continue
  interior=overlap
  for _ in range(a.scale):
   interior={i for i in interior if i%w>0 and i%w<w-1 and i//w>0 and i//w<h-1 and all(j in interior for j in [i-1,i+1,i-w,i+w])}
  if len(interior)<64*a.scale*a.scale:continue
  # Freeze a connected component without choosing it by exposure-fit error.
  occupied.update(overlap)
  split=statistics.median(i%w for i in interior);folds=[]
  for side in [False,True]:
   train=[i for i in interior if (i%w>=split)==side];held=[i for i in interior if (i%w>=split)!=side]
   if min(len(train),len(held))<24:continue
   gain=[statistics.median(second[i][c]-first[i][c] for i in train) for c in range(3)]
   errors=[second[i][c]-first[i][c]-gain[c] for i in held for c in range(3)]
   folds.append({'plane':plane(train,held,seed),'side':side,'channelEV':gain,'heldOutRMSEV':math.sqrt(statistics.mean(v*v for v in errors)),'heldOutMedianAbsoluteEV':statistics.median(map(abs,errors)),'trainingPixels':len(train),'heldOutPixels':len(held)})
  rows.append({'seed':[x,y],'overlapIoU':len(overlap)/len(union),'interiorPixels':len(interior),'bounds':[min(i%w for i in interior),min(i//w for i in interior),max(i%w for i in interior),max(i//w for i in interior)],'folds':folds,'consistent':len(folds)==2 and max(f['heldOutRMSEV'] for f in folds)<.04})
report={'status':'Diagnostic only; no identity guarantee, temporal target or rendered quality established.','source':str(a.thumbnails),'sourceFrames':[a.frame-1,a.frame],'coordinateScale':a.scale,'method':'Fixed spatial seeds; connected relative-log-chroma threshold .20 EV; source/target IoU>.75; intersection eroded once; median RGB gain fitted on one spatial half and evaluated on the other.','limitations':'Fixed-position overlap assumes negligible camera motion; similar colours can belong to different materials. Must validate geometry before any implementation. Overlapping components can be correlated.','regions':rows};a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(rows,indent=2))
