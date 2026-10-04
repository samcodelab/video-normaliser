"""Summarise full-resolution measurements from the native SpatialAudit app.
Run from the repository root after that app completes. Inputs are never modified.
"""
import hashlib, json, math, pathlib, shutil, statistics, subprocess
root = pathlib.Path('.build/audit')
out = pathlib.Path('dist/Spatial validation')
out.mkdir(parents=True, exist_ok=True)
data = [json.loads((root / f'spatial-final-patches-{i}.json').read_text()) for i in range(3)]
fields = json.loads((root / 'spatial-final-fields.json').read_text())
analysis = json.loads((root / 'spatial-final-analysis.json').read_text())
shots = [(0,10),(11,17),(25,37),(38,49),(50,85)]
# These boxes visibly contain moving figures in the contact sheets. Retain
# their measurements, but do not label their changes as static-patch flicker.
occluded = {(25,'right blue'),(50,'lower right wall')}
def rms(v): return math.sqrt(statistics.mean((b-a)**2 for a,b in zip(v,v[1:])))
def jump(v,start):
    return max(({'percent':abs(b-a)/max(.001,(a+b)/2)*100,'frame':start+i+1,'lumaLevels':abs(b-a)} for i,(a,b) in enumerate(zip(v,v[1:]))),key=lambda x:x['percent'])
rows=[]; summaries=[]
for start,end in shots:
    group=[]
    for k,region in enumerate(data[0][start]['regions']):
        series=[[q[f]['regions'][k] for f in range(start,end+1)] for q in data]
        vals=[[r['luma'] for r in s] for s in series]
        rr=[rms(v) for v in vals]
        residual=[]
        for pos,f in enumerate(range(start,end+1)):
            refs=[vals[2][j] for j in range(max(0,pos-6),min(len(vals[2]),pos+7)) if j!=pos]
            ref=statistics.median(refs)
            residual.append({'frame':f,'percent':100*(vals[2][pos]/ref-1)})
        colour=[]
        for s in series:
            ratios=[[r['rgb'][ch]/r['rgb'][1] for r in s] for ch in (0,2)]
            colour.append({'rgAdjacentRMS':rms(ratios[0]),'bgAdjacentRMS':rms(ratios[1])})
        row={'frames':[start,end],'name':region['name'],'sensorRect':region['sensorRect'],'displayRect':region['displayRect'],
             'containsMovingSubject':(start,region['name']) in occluded,'rmsSourceSuppliedCandidate':rr,
             'improvementVsSourcePercent':100*(1-rr[2]/rr[0]),'worstJumpCandidate':jump(vals[2],start),
             'maxAbsDeviationFromNearbyOutputMedianPercent':max(abs(x['percent']) for x in residual),
             'outputReferenceDeviations':residual,'colour':colour,'seriesSourceSuppliedCandidate':series}
        rows.append(row)
        if not row['containsMovingSubject']: group.append(row)
    means=[statistics.mean(r['rmsSourceSuppliedCandidate'][i] for r in group) for i in range(3)]
    worst=max(group,key=lambda r:r['worstJumpCandidate']['percent'])
    summaries.append({'frames':[start,end],'staticRegionCount':len(group),'meanRegionalRMS':means,
                      'reductionOfMeanRMSPercent':100*(1-means[2]/means[0]),
                      'worstJump':{'region':worst['name'],**worst['worstJumpCandidate']}})
focus=[]
for k,r in enumerate(data[2][12]['regions']):
    values=[[q[f]['regions'][k]['luma'] for f in (12,13,14)] for q in data]
    focus.append({'region':r['name'],'sourceSuppliedCandidate':values,
                  'frame13DeviationFromNeighboursPercent':[100*(v[1]/((v[0]+v[2])/2)-1) for v in values]})
logs=[]
for i,f in enumerate(fields):
    start=max(x for x in [0,11,18,38,50] if x<=i)
    logs.append({'frame':i,'time':data[0][i]['time'],'sceneStartFrame':start,'globalEV':analysis['stops'][i],
                 'globalGain':2**analysis['stops'][i],'spatial':f,
                 'requestedTotalGain':[2**(analysis['stops'][i]+v) for v in f['requested']],
                 'fittedTotalGainBeforePixelHighlightLimiter':[2**(analysis['stops'][i]+v) for v in f['applied']],
                 'predictedLinearAfter':[a*2**(analysis['stops'][i]+b) for a,b in zip(f['before'],f['applied'])],
                 'actualRegionsSource':data[0][i]['regions'],'actualRegionsCandidate':data[2][i]['regions']})
ff='/Applications/Parallels Toolbox.app/Contents/Frameworks/ToolboxCommon.framework/Versions/A/Resources/ToolboxCommon.bundle/Contents/MacOS/ffmpeg/ffprobe'
source='/Users/sam/Downloads/My_Stop_Motion_Movie(16).mov'
probes=[json.loads(subprocess.check_output([ff,'-v','error','-show_streams','-show_packets','-show_data_hash','sha256','-of','json',p])) for p in [source,str(root/'spatial-final.mov')]]
media={}
for kind in ['video','audio']:
    packets=[sorted([p for p in q['packets'] if p['codec_type']==kind],key=lambda p:int(p['pts'])) for q in probes]
    a,b=packets
    streams=[[s for s in q['streams'] if s['codec_type']==kind][0] for q in probes]
    media[kind]={'packetCounts':[len(a),len(b)],'exactPTSAndDuration':len(a)==len(b) and all((x['pts_time'],x['duration_time'])==(y['pts_time'],y['duration_time']) for x,y in zip(a,b)),
                 'streams':[{k:s.get(k) for k in ['width','height','avg_frame_rate','duration','nb_frames','side_data_list']} for s in streams]}
    if kind=='audio':media[kind]['exactPayloads']=len(a)==len(b) and all(x['data_hash']==y['data_hash'] for x,y in zip(a,b))
media['inputHashes']={}
for line in (root/'spatial-input-hashes.txt').read_text().splitlines():
    expected,p=line.split('  ',1);actual=hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
    media['inputHashes'][p]={'sha256':actual,'unchanged':actual==expected}
report={'method':'Full-resolution decoded sRGB, weighted luma 0.2126R+0.7152G+0.0722B, 0–255. RMS adjacent changes within shots. Equal weight per static ROI; moving-subject boxes retained separately. Coordinates normalised in encoded landscape and metadata-oriented display. Nearby-output median is an independent stability check, not the algorithm target. Independent boxes: external reviewer coordinates unavailable.',
        'settings':{'mode':'Smooth flicker','radiusSeconds':.5,'globalStrength':1,'spatialStrength':1,'reviewedCuts':[11,18,38,50],'automaticCuts':analysis['cuts']},
        'summaries':summaries,'frame12to14':focus,'regions':rows,'media':media,
        'fallbackFrames':[{'frame':i,'reason':f['fallback']} for i,f in enumerate(fields) if f.get('fallback')]}
(out/'Measurements.json').write_text(json.dumps(report,indent=2))
(out/'Frame diagnostics.json').write_text(json.dumps({'note':'Alignment reference indices are scene-local; add sceneStartFrame. Requested/applied fields are EV. Fitted gain and predicted brightness precede per-pixel highlight protection and encoding. ActualRegions contain measurements from the final encoded candidate. Confidence is heuristic, not a probability. Masks use displayed image bitmap coordinates.','frames':logs},indent=2))
for p in root.glob('review-*.png'):shutil.copy2(p,out/p.name)
for p in root.glob('detail-*.png'):shutil.copy2(p,out/p.name)
shutil.copy2(root/'spatial-final.mov','dist/Video Normaliser — Spatial Candidate.mov')
print(json.dumps({'summaries':summaries,'focus':focus,'fallback':report['fallbackFrames'],'media':media},indent=2))
