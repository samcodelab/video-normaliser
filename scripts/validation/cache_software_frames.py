import sys,ctypes as C,json
sys.path.insert(0,'scripts/validation')
from software_decode import frames
lib=C.CDLL('.build/software-video/sample.dylib');lib.sample.argtypes=[C.c_char_p,C.c_int,C.c_int,C.POINTER(C.c_float)]
thumbs=[];cells=[]
for w,h,rgb in frames('/Users/sam/Downloads/My_Stop_Motion_Movie(16) 2.mov'):
 out=(C.c_float*(96*56*3))();lib.sample(rgb,w,h,out);a=list(out);thumbs.append(dict(width=96,height=56,rgb=a))
 light=[sum(a[i+c]*v for c,v in enumerate([.2126,.7152,.0722])) for i in range(0,len(a),3)]
 cells.append([sum(light[y*96+x] for y in range(r*4,r*4+4) for x in range(c*4,c*4+4))/16 for r in range(14) for c in range(24)])
json.dump(thumbs,open('.build/audit/current-thumbnails.json','w'));json.dump(dict(cells=cells),open('.build/audit/current-analysis.json','w'))
