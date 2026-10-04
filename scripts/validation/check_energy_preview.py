import sys,json,pathlib,subprocess
sys.path.insert(0,'scripts/validation')
from software_decode import frames,png,ff
out=pathlib.Path('dist/Energy validation');r=json.loads((out/'measurements.json').read_text());data=[];tiles=[]
for n,(w,h,rgb) in enumerate(frames('dist/Video Normaliser — Estimator Preview.mov')):
 vals={}
 for name,box in r['source'][n].items():
  x,y,ww,hh=box['rect'];x0=int(x*w);x1=int((x+ww)*w);y0=int(y*h);y1=int((y+hh)*h);tot=[0,0,0]
  for yy in range(y0,y1):
   row=rgb[(yy*w+x0)*3:(yy*w+x1)*3]
   for c in range(3):tot[c]+=sum(row[c::3])
  vals[name]={'rect':box['rect'],'rgb':[v/((x1-x0)*(y1-y0)) for v in tot]}
 data.append(vals)
 tile=bytearray()
 for yy in range(216):
  for xx in range(384):
   p=(int(yy*h/216)*w+int(xx*w/384))*3;tile+=rgb[p:p+3]
 tiles.append(tile)
r['encodedPreview']=data;(out/'measurements.json').write_text(json.dumps(r,indent=2))
for page in range(4):
 group=tiles[page*24:(page+1)*24];canvas=bytearray(384*4*216*6*3)
 for j,tile in enumerate(group):
  for y in range(216):
   p=((j//4*216+y)*1536+j%4*384)*3;canvas[p:p+384*3]=tile[y*384*3:(y+1)*384*3]
 png(out/f'contact-{page*24}.png',1536,1296,canvas)
probe=str(pathlib.Path(ff).with_name('ffprobe'));probes=[]
for path in ['/Users/sam/Downloads/My_Stop_Motion_Movie(16) 2.mov','dist/Video Normaliser — Estimator Preview.mov']:
 probes.append(json.loads(subprocess.check_output([probe,'-v','error','-show_streams','-show_packets','-show_data_hash','sha256','-of','json',path])))
checks={}
for kind in ['video','audio']:
 pp=[sorted([p for p in q['packets'] if p['codec_type']==kind],key=lambda p:int(p['pts'])) for q in probes]
 checks[kind]={'counts':[len(p) for p in pp],'timestampsMatch':[[p.get('pts_time') for p in a] for a in pp][0]==[[p.get('pts_time') for p in a] for a in pp][1],'durationsMatch':[[p.get('duration_time') for p in a] for a in pp][0]==[[p.get('duration_time') for p in a] for a in pp][1]}
 if kind=='audio':checks[kind]['payloadsMatch']=[p['data_hash'] for p in pp[0]]==[p['data_hash'] for p in pp[1]]
checks['streams']=[q['streams'] for q in probes];(out/'media-checks.json').write_text(json.dumps(checks,indent=2));print(checks['video'],checks['audio'])
