"""Diagnostic colour-conditioned exposure metering; no production correction."""
import argparse,json,math,statistics
from collections import defaultdict
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('thumbnails',type=Path);p.add_argument('output',type=Path);p.add_argument('--first',type=int,required=True);p.add_argument('--end',type=int,required=True);a=p.parse_args();assert not a.output.exists()
images=json.loads(a.thumbnails.read_text())
def quantile(x,q):
 x=sorted(x);f=q*(len(x)-1);i=int(f);return x[i]*(1-f+i)+x[min(i+1,len(x)-1)]*(f-i)
def bins(im):
 result=defaultdict(list)
 for i in range(0,len(im['rgb']),3):
  r,g,b=im['rgb'][i:i+3]
  if min(r,g,b)<=.003 or max(r,g,b)>=.8:continue
  key=(math.floor(math.log2(r/g)/.25),math.floor(math.log2(b/g)/.25))
  result[key].append(math.log2(.2126*r+.7152*g+.0722*b))
 return {key:v for key,v in result.items() if len(v)>=24}
rows=[];prior=bins(images[a.first])
for frame in range(a.first+1,a.end):
 current=bins(images[frame]);measurements=[]
 for key in prior.keys()&current.keys():
  deltas=[quantile(current[key],q)-quantile(prior[key],q) for q in [.25,.5,.75]]
  if max(deltas)-min(deltas)>.06:continue
  measurements.append({'bin':key,'deltaEV':statistics.median(deltas),'counts':[len(prior[key]),len(current[key])]})
 delta=statistics.median(m['deltaEV'] for m in measurements) if measurements else None
 agreeing=[m for m in measurements if abs(m['deltaEV']-delta)<.05] if delta is not None else []
 rows.append({'frames':[frame-1,frame],'supportedBins':len(measurements),'consensusBins':len(agreeing),'medianDeltaEV':delta,'accepted':len(agreeing)>=3 and len(agreeing)*5>=len(measurements)*3,'bins':measurements})
 prior=current
report={'status':'Diagnostic only; no rendered or temporal-target quality established.','source':str(a.thumbnails),'method':'Log-chroma bins of width .25 EV, at least 24 unclipped samples per frame; corresponding quartiles must agree within .06 EV; at least three bins and 60% agreement within .05 EV.','limitations':'Reflectance distributions can change within bins. Coloured illumination moves bins. No geometry or clean illumination reference.','transitions':rows};a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps([{k:v for k,v in r.items() if k!='bins'} for r in rows],indent=2))
