"""Clip-specific estimator replay. Run from repository root with x86_64 Python.
Requires software decoder libraries, sample.dylib, and baseline/weighted field
caches in .build/audit. Source movies are read only. The MPEG-4 preview is an
audit artifact, not a native Core Image export. Measurements precede encoding.
"""
import sys,ctypes as C,json,pathlib,re,subprocess
sys.path.insert(0,'scripts/validation')
from software_decode import frames,png,ff
lib=C.CDLL('.build/software-video/sample.dylib');lib.render.argtypes=[C.c_void_p,C.c_int,C.c_int,C.POINTER(C.c_double),C.c_double]
text=pathlib.Path('scripts/validation/SpatialAudit.swift').read_text();section=text.split('let shotRegions:')[1].split('for (fileIndex')[0]
shots=[]
for line in section.splitlines():
 boxes=re.findall(r'\("([^"]+)",CGRect\(x:([.\d]+),y:([.\d]+),width:([.\d]+),height:([.\d]+)\)\)',line)
 if boxes:shots.append([(a,tuple(map(float,(b,c,d,e)))) for a,b,c,d,e in boxes])
assert len(shots)==5,len(shots)
F={l:json.load(open('.build/audit/'+l+'-fields.json')) for l in ['baseline','weighted']};G=json.load(open('.build/audit/weighted-global.json'));reports={l:[] for l in ['source','supplied','baseline','weighted']}
out=pathlib.Path('dist/Energy validation');out.mkdir(exist_ok=True)
def measure(rgb,w,h,n):
 shot=0 if n<11 else 1 if n<18 else 2 if n<38 else 3 if n<50 else 4
 vals={}
 for name,(x,y,ww,hh) in shots[shot]:
  x0=int(x*w);x1=int((x+ww)*w);y0=int(y*h);y1=int((y+hh)*h);tot=[0,0,0]
  for yy in range(y0,y1):
   row=rgb[(yy*w+x0)*3:(yy*w+x1)*3]
   for c in range(3):tot[c]+=sum(row[c::3])
  vals[name]={'rect':[x,y,ww,hh],'rgb':[v/((x1-x0)*(y1-y0)) for v in tot]}
 return vals
raw=pathlib.Path('.build/audit/energy-preview.rgb')
with raw.open('wb') as stream:
 for n,(w,h,rgb) in enumerate(frames('/Users/sam/Downloads/My_Stop_Motion_Movie(16) 2.mov')):
  reports['source'].append(measure(rgb,w,h,n))
  for label in ['baseline','weighted']:
   buf=C.create_string_buffer(rgb);field=(C.c_double*54)(*F[label][n]['stops']);lib.render(buf,w,h,field,G[n]);rendered=buf.raw[:-1]
   reports[label].append(measure(rendered,w,h,n))
   if label=='weighted':
    stream.write(rendered)
    if n in [12,13,14]:png(out/f'candidate-frame-{n}.png',w,h,rendered)
  if n%20==0:print('Rendered',n,flush=True)
for n,(w,h,rgb) in enumerate(frames('/Users/sam/Downloads/My_Stop_Motion_Movie(16) 2 — Normalised.mov')):reports['supplied'].append(measure(rgb,w,h,n))
(out/'measurements.json').write_text(json.dumps(reports,indent=2))
subprocess.run([ff,'-v','error','-n','-f','rawvideo','-pixel_format','rgb24','-video_size','3840x2160','-framerate','12','-i',str(raw),'-i','/Users/sam/Downloads/My_Stop_Motion_Movie(16) 2.mov','-map','0:v:0','-map','1:a:0','-c:v','mpeg4','-q:v','2','-pix_fmt','yuv420p','-c:a','copy','-movie_timescale','88200','-video_track_timescale','600','-colorspace','bt709','-color_trc','bt709','-color_primaries','bt709','dist/Video Normaliser — Estimator Preview.mov'],check=True)
raw.unlink()
