"""Diagnostic RGB exposure from colour-distribution alignment, without motion warps."""
import argparse,json,math,statistics
from collections import defaultdict
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('thumbnails',type=Path);p.add_argument('output',type=Path);p.add_argument('--first',type=int,required=True);p.add_argument('--end',type=int,required=True);a=p.parse_args();assert not a.output.exists()
images=json.loads(a.thumbnails.read_text())
def quantile(x,q):
 x=sorted(x);f=q*(len(x)-1);i=int(f);return x[i]*(1-f+i)+x[min(i+1,len(x)-1)]*(f-i)
def pixels(im):
 out=[]
 for i in range(0,len(im['rgb']),3):
  rgb=im['rgb'][i:i+3]
  if min(rgb)<=.003 or max(rgb)>=.8:continue
  levels=[math.log2(v) for v in rgb];out.append(levels)
 return out
def bins(values,sr=0,sb=0):
 groups=defaultdict(list)
 for r,g,b in values:groups[(math.floor((r-g-sr)/.25),math.floor((b-g-sb)/.25))].append([r,g,b])
 return {k:([quantile([v[c] for v in group],q) for c in range(3) for q in [.25,.5,.75]],len(group)) for k,group in groups.items() if len(group)>=24}
rows=[]
for frame in range(a.first+1,a.end):
 prior=bins(pixels(images[frame-1]));current=pixels(images[frame]);candidates=[]
 for sr in [-.25,-.125,0,.125,.25]:
  for sb in [-.25,-.125,0,.125,.25]:
   other=bins(current,sr,sb);measurements=[]
   for key in prior.keys()&other.keys():
    x,n=prior[key];y,m=other[key];delta=[statistics.median([y[c*3+j]-x[c*3+j] for j in range(3)]) for c in range(3)]
    spread=max(max(y[c*3+j]-x[c*3+j] for j in range(3))-min(y[c*3+j]-x[c*3+j] for j in range(3)) for c in range(3))
    if spread>.08:continue
    measurements.append({'bin':key,'channelEV':delta,'counts':[n,m]})
   if len(measurements)<3:continue
   gain=[statistics.median(v['channelEV'][c] for v in measurements) for c in range(3)]
   if abs(gain[0]-gain[1]-sr)>.125 or abs(gain[2]-gain[1]-sb)>.125:continue
   agreeing=[v for v in measurements if max(abs(v['channelEV'][c]-gain[c]) for c in range(3))<.06]
   candidates.append({'chromaShift':[sr,sb],'channelEV':gain,'supportedBins':len(measurements),'consensusBins':len(agreeing),'supportPixels':sum(min(v['counts']) for v in agreeing),'bins':measurements})
 # More independently represented agreeing colour groups takes priority;
 # sample count only breaks ties, without authorizing a production correction.
 chosen=max(candidates,key=lambda v:(v['consensusBins'],v['supportPixels'])) if candidates else None
 rows.append({'frames':[frame-1,frame],'selected':chosen,'accepted':bool(chosen and chosen['consensusBins']>=3 and chosen['consensusBins']*5>=chosen['supportedBins']*3)})
report={'status':'Diagnostic only; no clean illumination reference or correction quality established.','source':str(a.thumbnails),'method':'Align log-chroma distributions, then require corresponding RGB quartiles and agreement among independent colour bins.','limitations':'Material mixtures and selection can manufacture gain; chroma bins are not independent physical surfaces. Requires controlled tests before implementation.','transitions':rows};a.output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps([{**r,'selected':{k:v for k,v in r['selected'].items() if k!='bins'} if r['selected'] else None} for r in rows],indent=2))
