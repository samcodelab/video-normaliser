"""Read-only H.264/MPEG-4 audit using the locally installed FFmpeg 5.1 libraries.
Run with arch -x86_64 /usr/bin/python3. Libraries copied into .build/software-video.
API sequence follows https://ffmpeg.org/doxygen/5.1/decode_video_8c-example.html
"""
import ctypes as C, subprocess, pathlib, json, sys, zlib, struct, tempfile
P=C.c_void_p; I=C.c_int; U=C.POINTER(C.c_uint8)
class Frame(C.Structure):
    _fields_=[('data',U*8),('linesize',I*8),('extended_data',P),('width',I),('height',I),('nb_samples',I),('format',I)]
class Packet(C.Structure):
    _fields_=[('buf',P),('pts',C.c_int64),('dts',C.c_int64),('data',U),('size',I)]
base=pathlib.Path('.build/software-video')
codec=C.CDLL(str(base/'libavcodec.59.dylib')); util=C.CDLL(str(base/'libavutil.57.dylib')); scale=C.CDLL(str(base/'libswscale.6.dylib'))
def fn(lib,name,ret,args):
    f=getattr(lib,name);f.restype=ret;f.argtypes=args;return f
find=fn(codec,'avcodec_find_decoder_by_name',P,[C.c_char_p]);alloc=fn(codec,'avcodec_alloc_context3',P,[P]);open_=fn(codec,'avcodec_open2',I,[P,P,P]);parser_init=fn(codec,'av_parser_init',P,[I])
parse=fn(codec,'av_parser_parse2',I,[P,P,C.POINTER(U),C.POINTER(I),U,I,C.c_int64,C.c_int64,C.c_int64])
packet_alloc=fn(codec,'av_packet_alloc',C.POINTER(Packet),[]);frame_alloc=fn(util,'av_frame_alloc',C.POINTER(Frame),[])
send=fn(codec,'avcodec_send_packet',I,[P,P]);receive=fn(codec,'avcodec_receive_frame',I,[P,P])
get_context=fn(scale,'sws_getContext',P,[I,I,I,I,I,I,I,P,P,P]);sws=fn(scale,'sws_scale',I,[P,C.POINTER(U),C.POINTER(I),I,I,C.POINTER(U),C.POINTER(I)])
pixfmt=fn(util,'av_get_pix_fmt',I,[C.c_char_p]);free_scale=fn(scale,'sws_freeContext',None,[P])
ff='/Applications/Parallels Toolbox.app/Contents/Frameworks/ToolboxCommon.framework/Versions/A/Resources/ToolboxCommon.bundle/Contents/MacOS/ffmpeg/ffmpeg'
def frames(path):
    probe=str(pathlib.Path(ff).with_name('ffprobe'))
    info=json.loads(subprocess.check_output([probe,'-v','error','-select_streams','v:0','-show_entries','stream=codec_name','-of','json',path]))
    name=info['streams'][0]['codec_name']
    assert name in ('h264','mpeg4'),name
    with tempfile.TemporaryDirectory(dir='.build/software-video') as tmp:
        bitstream=pathlib.Path(tmp)/'frames.bin'
        extra=['-bsf:v','h264_mp4toannexb','-f','h264'] if name=='h264' else ['-f','m4v']
        subprocess.run([ff,'-v','error','-i',path,'-map','0:v:0','-c:v','copy']+extra+[str(bitstream)],check=True)
        raw=bitstream.read_bytes()
        if name=='mpeg4':
            header=json.loads(subprocess.check_output([probe,'-v','error','-select_streams','v:0','-show_entries','stream=extradata','-show_data','-of','json',path]))['streams'][0]['extradata']
            prefix=b''.join(bytes.fromhex(line.split(': ',1)[1][:39]) for line in header.splitlines() if ': ' in line)
            raw=prefix+raw
    buf=C.create_string_buffer(raw+b'\0'*64);address=C.addressof(buf);offset=0
    decoder=find(name.encode());ctx=alloc(decoder);assert open_(ctx,decoder,None)>=0
    parser=parser_init(27 if name=='h264' else 12);packet=packet_alloc();frame=frame_alloc();conversion=None;storage=None
    def decode(pkt):
        nonlocal conversion,storage
        assert send(ctx,pkt)>=0
        while True:
            status=receive(ctx,frame)
            if status in (-35,-11,-541478725):return
            assert status>=0,status
            f=frame.contents
            assert 1<=f.width<=8192 and 1<=f.height<=8192,(f.width,f.height)
            if conversion is None:
                conversion=get_context(f.width,f.height,f.format,f.width,f.height,pixfmt(b'rgb24'),2,None,None,None)
                # Match Rec.709 YUV coefficients, full-range RGB output.
                coeff=fn(scale,'sws_getCoefficients',C.POINTER(I),[I])(1)
                fn(scale,'sws_setColorspaceDetails',I,[P,C.POINTER(I),I,C.POINTER(I),I,I,I,I])(conversion,coeff,0,coeff,1,0,1<<16,1<<16)
                storage=(C.c_uint8*(f.width*f.height*3))()
            dst=(U*4)(C.cast(storage,U),U(),U(),U());lines=(I*4)(f.width*3,0,0,0)
            assert sws(conversion,f.data,f.linesize,0,f.height,dst,lines)==f.height
            yield f.width,f.height,bytes(storage)
    while offset<len(raw):
        dest=U();size=I();used=parse(parser,ctx,C.byref(dest),C.byref(size),C.cast(address+offset,U),len(raw)-offset,-(1<<63),-(1<<63),0)
        assert used>=0
        offset+=used
        if size.value:
            packet.contents.data=dest;packet.contents.size=size.value
            yield from decode(packet)
        elif used==0:raise RuntimeError('Parser made no progress')
    dest=U();size=I();parse(parser,ctx,C.byref(dest),C.byref(size),U(),0,-(1<<63),-(1<<63),0)
    if size.value:
        packet.contents.data=dest;packet.contents.size=size.value;yield from decode(packet)
    yield from decode(None)
    free_scale(conversion)
    fn(codec,'av_parser_close',None,[P])(parser)
    p=P(ctx);fn(codec,'avcodec_free_context',None,[C.POINTER(P)])(C.byref(p))
def png(path,w,h,rgb):
    def chunk(k,v):return struct.pack('>I',len(v))+k+v+struct.pack('>I',zlib.crc32(k+v)&0xffffffff)
    data=b''.join(b'\0'+rgb[y*w*3:(y+1)*w*3] for y in range(h))
    pathlib.Path(path).write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(data,3))+chunk(b'IEND',b''))
if __name__=='__main__':
    output=pathlib.Path(sys.argv[2]);output.mkdir(exist_ok=True,parents=True)
    regions=[('upper wall',(.38,.03,.22,.15)),('lower left wall',(.02,.48,.12,.20)),('left floor',(.02,.88,.14,.10))]
    report=[]
    for n,(w,h,rgb) in enumerate(frames(sys.argv[1])):
        values={}
        for name,(x,y,ww,hh) in regions:
            x0=int(x*w);x1=int((x+ww)*w);y0=int(y*h);y1=int((y+hh)*h)
            total=[0,0,0]
            for yy in range(y0,y1):
                row=rgb[(yy*w+x0)*3:(yy*w+x1)*3]
                for c in range(3):total[c]+=sum(row[c::3])
            mean=[v/((x1-x0)*(y1-y0)) for v in total]
            values[name]={'rgb':mean,'luma':sum(a*b for a,b in zip(mean,[.2126,.7152,.0722]))}
        report.append(values)
        if n in [11,12,13,14,15,16,17]:png(output/f'frame-{n}.png',w,h,rgb)
    (output/'regions.json').write_text(json.dumps(report,indent=2))
    print('Decoded',len(report),'frames',flush=True)
    print([[i,{k:round(v['luma'],2) for k,v in report[i].items()}] for i in [11,12,13,14,15,16,17]])
