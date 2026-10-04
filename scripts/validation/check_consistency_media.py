"""Check native audit exports against source packet timing and audio payloads."""
import json,pathlib,subprocess,sys
probe='/Applications/Parallels Toolbox.app/Contents/Frameworks/ToolboxCommon.framework/Versions/A/Resources/ToolboxCommon.bundle/Contents/MacOS/ffmpeg/ffprobe'
data=[json.loads(subprocess.check_output([probe,'-v','error','-show_streams','-show_packets','-show_data_hash','sha256','-of','json',p])) for p in sys.argv[1:3]]
checks={}
for kind in ['video','audio']:
 packets=[sorted([p for p in d['packets'] if p['codec_type']==kind],key=lambda p:int(p['pts'])) for d in data]
 checks[kind]={'counts':[len(p) for p in packets],**{k:([p.get(k) for p in packets[0]]==[p.get(k) for p in packets[1]]) for k in ['pts_time','duration_time']}}
 if kind=='audio':checks[kind]['payloadsMatch']=[p['data_hash'] for p in packets[0]]==[p['data_hash'] for p in packets[1]]
 streams=[[s for s in d['streams'] if s['codec_type']==kind] for d in data]
 checks[kind]['streams']=[{k:s.get(k) for k in ['width','height','duration','avg_frame_rate','sample_rate','channels','side_data_list']} for group in streams for s in group]
print(json.dumps(checks,indent=2))
assert all(checks[k]['pts_time'] and checks[k]['duration_time'] and checks[k]['counts'][0]==checks[k]['counts'][1] for k in ['video','audio'])
assert checks['audio']['payloadsMatch']
