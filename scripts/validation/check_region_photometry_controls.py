"""Run measurement diagnostics against known light changes and moving boundaries."""
import json,math,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parents[2];out=root/'.build/review-v33/region-photometry-experiment/controls-v1';out.mkdir(parents=True,exist_ok=False)
results=[]
for name,ev,occluded in [('uniform-coloured-gain',[.4,-.3,.2],False),('moving-boundary-clean',[0,0,0],False),('independent-material-light',[.25,.25,.25],False),('changed-texture-occlusion',[0,0,0],True)]:
 images=[]
 for frame in [0,1]:
  rgb=[]
  for y in range(40):
   for x in range(48):
    boundary=24 if frame==0 else 22
    material=[.08,.20,.10] if x<boundary else [.20,.08,.10]
    shade=1+.1*math.sin(x*.8+y*.7)
    if frame==1 and occluded:shade=1+.3*math.cos(x*1.3-y*.9)
    gain=ev if x<boundary else ([1,1,1] if name=='independent-material-light' else [0,0,0])
    rgb.extend(v*shade*2**(gain[c] if frame else 0) for c,v in enumerate(material))
  images.append({'width':48,'height':40,'rgb':rgb})
 source=out/f'{name}-thumbnails.json';source.write_text(json.dumps(images))
 tracking=out/f'{name}-tracking.json';tracking.write_text(json.dumps({'tracks':[{'observations':[{'frame':i,'x':20,'y':20,'offsetX':0,'offsetY':0} for i in [0,1]]}]}))
 destination=out/f'{name}-report.json'
 subprocess.run([sys.executable,str(root/'scripts/validation/audit_region_photometry.py'),str(source),str(tracking),str(destination),'--first-frame','0','--frame','1'],check=True,capture_output=True)
 d=json.loads(destination.read_text());assert d['summary']['comparablePatches']==1,(name,d['summary'])
 folds=d['patches'][0]['folds'];measured=[sum(f['regionChannelEV'][c] for f in folds)/2 for c in range(3)];error=max(abs(measured[c]-ev[c]) for c in range(3));rms=max(f['regionHeldOutRMSEV'] for f in folds)
 if not occluded:assert error<1e-10 and rms<1e-10,(name,error,rms)
 else:assert rms>.1,(name,rms)
 results.append({'case':name,'knownChannelEV':ev,'measuredChannelEV':measured,'maximumHeldOutRMSEV':rms,'pass':True,'interpretation':'Changed texture must fail a photometric consistency gate.' if occluded else 'Interior metering retains known exposure despite boundary motion.'})
report={'status':'Synthetic measurement checks only; no renderer or real-video quality established.','controls':results};(out/'summary.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(results,indent=2))
