"""Report both the supplied export and the controlled CPU estimator replay."""
import json,math,pathlib,statistics
out=pathlib.Path('dist/Energy validation');r=json.loads((out/'measurements.json').read_text())
labels=['source','supplied','baseline','weighted'] + (['encodedPreview'] if 'encodedPreview' in r else []);shots=[(0,10),(11,17),(25,37),(38,49),(50,85),(79,85)]
excluded={(25,'right blue'),(50,'lower right wall'),(79,'lower right wall')}
def y(v):return sum(a*b for a,b in zip(v['rgb'],[.2126,.7152,.0722]))
def rms(v):return math.sqrt(statistics.mean((b-a)**2 for a,b in zip(v,v[1:])))
summary=[];regions=[]
for start,end in shots:
 rows=[]
 for name in r['source'][start]:
  values={l:[y(r[l][i][name]) for i in range(start,end+1)] for l in labels}
  row={'name':name,'frames':[start,end],'excludedMovingSubject':(start,name) in excluded,'rms':{l:rms(v) for l,v in values.items()},'worstJump':{}}
  for l,v in values.items():row['worstJump'][l]=max([{'percent':100*abs(b-a)/((a+b)/2),'levels':abs(b-a),'frame':start+i+1} for i,(a,b) in enumerate(zip(v,v[1:]))],key=lambda q:q['percent'])
  row['colourRatioRMS']={l:{ch:rms([r[l][i][name]['rgb'][c]/r[l][i][name]['rgb'][1] for i in range(start,end+1)]) for ch,c in [('R/G',0),('B/G',2)]} for l in labels}
  regions.append(row)
  if not row['excludedMovingSubject']:rows.append(row)
 means={l:statistics.mean(row['rms'][l] for row in rows) for l in labels};worst=max(rows,key=lambda q:q['worstJump']['weighted']['percent'])
 summary.append({'frames':[start,end],'meanPatchRMS':means,'worstCandidateJump':{'region':worst['name'],**worst['worstJump']['weighted']},'improvementVsSourcePercent':100*(1-means['weighted']/means['source'])})
focus=[]
for name in r['source'][12]:
 values={l:[y(r[l][i][name]) for i in (12,13,14)] for l in labels}
 focus.append({'region':name,'values':values,'candidateDeviationPercent':100*(values['weighted'][1]/statistics.mean([values['weighted'][0],values['weighted'][2]])-1)})
(out/'summary.json').write_text(json.dumps(dict(summary=summary,regions=regions,focus=focus),indent=2))
print(json.dumps(dict(summary=summary,focus=focus),indent=2))
