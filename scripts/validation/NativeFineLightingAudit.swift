// Experimental native ROI gain-field fit. No shipping call site; no output image geometry changes.
import Foundation
import AVFoundation
import CoreImage

@main struct NativeFineLightingAudit {
    struct Measurement {
        let event:Int
        let points:[(x:Double,y:Double)]
        let sourcePulse:Double
        let heldError:Double
        let active:Bool
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 12,let first = Int(args[3]),let end = Int(args[4]),let width = Int(args[5]),
              let left = Int(args[6]),let bottom = Int(args[7]),let columns = Int(args[8]),let rows = Int(args[9]),let amount = Double(args[11]),
              first >= 0,end-first >= 5,end-first <= 17,(96...768).contains(width),width%96 == 0,
              left >= 0,bottom >= 0,columns >= 5,rows >= 5,left+columns <= 96,bottom+rows <= 56,amount.isFinite,(0...1).contains(amount) else {
            throw VideoError.message("Usage: source diagnostics first end width left top columns rows output-folder amount")
        }
        let out = URL(fileURLWithPath:args[10]),folder = URL(fileURLWithPath:args[2])
        guard !FileManager.default.fileExists(atPath:out.path) else {throw VideoError.message("Fresh output required")}
        let scale = width/96,height = 56*scale,x0 = left*scale,y0 = bottom*scale,w = columns*scale,h = rows*scale
        guard w*h <= 65536 else {throw VideoError.message("ROI exceeds bounded descriptor budget")}
        let decoder = JSONDecoder(),encoder = JSONEncoder()
        let original = try decoder.decode([SpatialField].self,from:Data(contentsOf:folder.appendingPathComponent("spatial-fields.json")))
        let stops = try decoder.decode([Double].self,from:Data(contentsOf:folder.appendingPathComponent("global-stops.json")))
        guard end <= original.count,end <= stops.count,(first..<end).allSatisfy({original[$0].surface != nil && original[$0].surface?.rowModel != true}) else {throw VideoError.message("Missing supported surface maps")}
        let asset = AVURLAsset(url:URL(fileURLWithPath:args[1]))
        guard let track = try await asset.loadTracks(withMediaType:.video).first else {throw VideoError.message("No video")}
        let preferred = try await track.load(.preferredTransform),natural = try await track.load(.naturalSize)
        let transform = VideoGeometry.coreImageTransform(preferred:preferred,naturalSize:natural)
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false;reader.add(output)
        guard reader.startReading() else {throw reader.error ?? VideoError.message("Decode failed")}
        defer {reader.cancelReading()}
        let linear = CGColorSpace(name:CGColorSpace.linearSRGB)!
        let context = CIContext(options:[.workingColorSpace:linear,.cacheIntermediates:false])
        var frames:[SpatialThumbnail] = [],times:[Double] = [],index = 0
        while let sample = output.copyNextSampleBuffer() {
            defer {index += 1}
            if index >= end {break}
            guard index >= first else {continue}
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {throw VideoError.message("Missing pixel buffer")}
            let frame = CIImage(cvPixelBuffer:buffer).transformed(by:transform),extent = frame.extent
            let small = frame.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY))
                .applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:Double(height)/extent.height,kCIInputAspectRatioKey:Double(width)/extent.width/(Double(height)/extent.height)])
            // Extract by bitmap row index from one full-frame render. This
            // removes crop-origin conversion and tile-dependent resampling.
            var whole = [Float](repeating:0,count:width*height*4)
            whole.withUnsafeMutableBytes {context.render(small,toBitmap:$0.baseAddress!,rowBytes:width*16,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBAf,colorSpace:linear)}
            var rgba = [Float](repeating:0,count:w*h*4)
            for y in 0..<h {for x in 0..<w {for c in 0..<4 {
                rgba[(y*w+x)*4+c] = whole[((y+y0)*width+x+x0)*4+c]
            }}}
            if frames.isEmpty {print("ROI_EXTRACTED_FROM_FULL_RASTER",x0,y0,w,h)}
            let rgb = (0..<w*h*3).map {rgba[($0/3)*4+$0%3]}
            frames.append(.init(width:w,height:h,rgb:rgb));times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        guard frames.count == end-first else {throw reader.error ?? VideoError.message("Incomplete interval")}
        reader.cancelReading()
        let timingReader = try AVAssetReader(asset:asset)
        let timingOutput = AVAssetReaderTrackOutput(track:track,outputSettings:nil)
        timingReader.add(timingOutput)
        guard timingReader.startReading() else {throw VideoError.message("Timing decode failed")}
        var allTimes:[Double] = []
        while let sample = timingOutput.copyNextSampleBuffer() {
            if CMSampleBufferGetNumSamples(sample) > 0 {allTimes.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)}
        }
        allTimes.sort()
        guard timingReader.status == .completed,allTimes.count == stops.count,
              Set(allTimes).count == allTimes.count,
              zip(times,allTimes[first..<end]).allSatisfy({abs($0.0-$0.1) < 1e-8}) else {
            throw VideoError.message("Decoded ROI does not match source frame PTS")
        }
        let prepared = frames.map {SurfaceTracking.Prepared($0)},n = frames.count
        var full:[SpatialThumbnail] = []
        // The padded pixels are never measured or exported. Full-image coordinates
        // preserve the native renderer's map sampling on the measured ROI.
        for frame in frames {
            var rgb = [Float](repeating:0,count:width*height*3)
            for y in 0..<h {for x in 0..<w {for c in 0..<3 {rgb[((y+y0)*width+x+x0)*3+c] = frame.rgb[(y*w+x)*3+c]}}}
            full.append(.init(width:width,height:height,rgb:rgb))
        }
        func taps(_ point:SurfaceTracking.Observation) -> [(x:Double,y:Double)] {
            (-2...2).flatMap {dy in (-2...2).map {dx in (Double(x0+point.x+dx)+point.offsetX,Double(y0+point.y+dy)+point.offsetY)}}
        }
        func sample(_ image:SpatialThumbnail,_ points:[(x:Double,y:Double)]) -> [Double]? {
            var result:[Double] = []
            for point in points {
                let ix = Int(floor(point.x)),iy = Int(floor(point.y)),fx = point.x-Double(ix),fy = point.y-Double(iy)
                guard ix >= x0,iy >= y0,ix+1 < x0+w,iy+1 < y0+h else {return nil}
                for c in 0..<3 {
                    let p = (iy*width+ix)*3+c
                    let a = Double(image.rgb[p])*(1-fx)+Double(image.rgb[p+3])*fx
                    let b = Double(image.rgb[p+width*3])*(1-fx)+Double(image.rgb[p+width*3+3])*fx
                    result.append(a*(1-fy)+b*fy)
                }
            }
            return result
        }
        func level(_ pixels:[Double]) -> Double {
            log2(max(1e-9,(0..<25).reduce(0.0) {$0+0.2126*pixels[$1*3]+0.7152*pixels[$1*3+1]+0.0722*pixels[$1*3+2]}/25))
        }
        var measures:[Measurement] = [],rejections:[String:Int] = [:]
        for event in 1..<(n-1) {
            var eventMeasures:[Measurement] = []
            for y in stride(from:7,to:h-7,by:8) {for x in stride(from:7,to:w-7,by:8) {
                let track = SurfaceTracking.trajectoryThrough(prepared,segments:Array(repeating:0,count:n),anchor:event,x:x,y:y)
                guard track.count >= 4,track.allSatisfy({$0.confidence > 0}),
                      let a = track.first(where:{$0.frame == event-1}),let b = track.first(where:{$0.frame == event}),let c = track.first(where:{$0.frame == event+1}) else {rejections["geometry",default:0] += 1;continue}
                let points = [a,b,c].map(taps)
                let values = zip([event-1,event,event+1],points).compactMap {sample(full[$0.0],$0.1)}
                guard values.count == 3 else {continue}
                let alpha = (times[event]-times[event-1])/(times[event+1]-times[event-1])
                let evidence = CommonIlluminationComponent.pulseLuminancePixels(before:values[0],middle:values[1],after:values[2],alpha:alpha,tolerance:0.04)
                guard evidence.rejection == nil else {rejections[evidence.rejection!,default:0] += 1;continue}
                let pulse = level(values[1])-(1-alpha)*level(values[0])-alpha*level(values[2])
                eventMeasures.append(.init(event:event,points:points.flatMap {$0},sourcePulse:pulse,heldError:evidence.heldError,active:abs(pulse) > 0.08))
            }}
            // Footprint count, not an independence or illumination-truth classifier.
            // Source-correlated deliberate flashes can pass this research gate.
            for measure in eventMeasures {
                let sameSign = eventMeasures.filter {$0.active && $0.sourcePulse*measure.sourcePulse > 0}
                let allowed = sameSign.count >= 4
                measures.append(.init(event:measure.event,points:measure.points,sourcePulse:measure.sourcePulse,heldError:measure.heldError,active:measure.active && allowed))
            }
        }
        let toneFit = ProcessInfo.processInfo.environment["FRANKLUMA_FINE_TONE_FIT"] == "1"
        var candidate = original
        struct Row {let terms:[(Int,Double)];let error:Double;let weight:Double}
        func pulseAndTerms(_ m:Measurement,_ fields:[SpatialField]) -> (Double,[(Int,Double)])? {
            let alpha = (times[m.event]-times[m.event-1])/(times[m.event+1]-times[m.event-1])
            let factors = [-(1-alpha),1.0,-alpha]
            var values:[Double] = [],terms:[(Int,Double)] = []
            for k in 0..<3 {
                let i = m.event+k-1,map = fields[first+i].surface!,points = Array(m.points[(k*25)..<((k+1)*25)])
                let global = stops[first+i]+(fields[first+i].brightnessEV ?? 0)
                guard let source = sample(full[i],points),let gain = SpatialRenderer.sampledSurfaceGain(image:full[i],map:map,global:global,points:points,validPixels:Array(0..<25)),
                      let derivative = SpatialRenderer.surfaceGainJacobian(image:full[i],map:map,global:global,point:(Int(points[12].x),Int(points[12].y)),footprint:points,validPixels:Array(0..<25)) else {return nil}
                values.append(level(source)+gain)
                // Fixed endpoints constrain the interval boundary; scene mean is not constrained.
                if i > 0 && i < n-1 {
                    for (node,weight) in derivative {terms.append((i*2*map.width*map.height+node,factors[k]*weight))}
                    if toneFit,let tonal = SpatialRenderer.surfaceGainJacobian(image:full[i],map:map,global:global,point:(Int(points[12].x),Int(points[12].y)),footprint:points,validPixels:Array(0..<25),toneDerivative:true) {
                        for (node,weight) in tonal {terms.append(((i*2+1)*map.width*map.height+node,factors[k]*weight))}
                    }
                }
            }
            return (zip(values,factors).reduce(0) {$0+$1.0*$1.1},terms)
        }
        let spacing = Int(ProcessInfo.processInfo.environment["FRANKLUMA_FINE_GRID_SPACING"] ?? "1") ?? 1
        guard [1,2,4,8].contains(spacing),let firstMap = original[first].surface,firstMap.width%spacing == 0,firstMap.height%spacing == 0 else {throw VideoError.message("Invalid refinement basis spacing")}
        let gridWidth = firstMap.width/spacing,gridHeight = firstMap.height/spacing,gridCount = gridWidth*gridHeight
        func coarseTerms(_ key:Int) -> [(Int,Double)] {
            let mapCount = firstMap.width*firstMap.height,frame = key/mapCount,node = key%mapCount
            return SpatialRenderer.surfaceBasis(x:(Double(node%firstMap.width)+0.5)/Double(firstMap.width),y:(Double(node/firstMap.width)+0.5)/Double(firstMap.height),width:gridWidth,height:gridHeight).map {(frame*gridCount+$0.0,$0.1)}
        }
        var acceptedPasses = 0
        for _ in 0..<3 where amount > 0 {
            var rowsFit:[Row] = []
            for m in measures {
                guard let (pulse,terms) = pulseAndTerms(m,candidate),let old = pulseAndTerms(m,original)?.0 else {continue}
                let target = m.active ? old+amount*(-m.sourcePulse-(old-m.sourcePulse)) : old
                var merged:[Int:Double] = [:]
                for (key,coefficient) in terms {for (gridKey,weight) in coarseTerms(key) {merged[gridKey,default:0] += coefficient*weight}}
                rowsFit.append(.init(terms:merged.keys.sorted().map {($0,merged[$0]!)},error:pulse-target,weight:m.active ? 1 : 4))
            }
            let keys = Array(Set(rowsFit.flatMap {$0.terms.map {$0.0}})).sorted(),lookup = Dictionary(uniqueKeysWithValues:keys.enumerated().map {($0.element,$0.offset)})
            guard !keys.isEmpty else {break}
            let local = rowsFit.map {Row(terms:$0.terms.map {(lookup[$0.0]!,$0.1)},error:$0.error,weight:$0.weight)}
            let ridge = 0.05
            func multiply(_ x:[Double]) -> [Double] {
                var y = x.map {$0*ridge}
                for row in local {
                    let v = row.terms.reduce(0.0) {$0+x[$1.0]*$1.1}*row.weight
                    for (j,c) in row.terms {y[j] += c*v}
                }
                return y
            }
            var rhs = Array(repeating:0.0,count:keys.count)
            for row in local {for (j,c) in row.terms {rhs[j] -= row.weight*c*row.error}}
            var delta = Array(repeating:0.0,count:keys.count),r = rhs,p = r
            func dot(_ a:[Double],_ b:[Double]) -> Double {zip(a,b).reduce(0) {$0+$1.0*$1.1}}
            var rr = dot(r,r)
            for _ in 0..<400 {
                if rr < 1e-14 {break}
                let ap = multiply(p),denominator = dot(p,ap)
                guard denominator > 1e-16 else {break}
                let alpha = rr/denominator
                for j in delta.indices {delta[j] += alpha*p[j];r[j] -= alpha*ap[j]}
                let next = dot(r,r),beta = next/rr
                for j in p.indices {p[j] = r[j]+beta*p[j]};rr = next
            }
            let count = original[first].surface!.width*original[first].surface!.height
            let oldError = rowsFit.reduce(0.0) {$0+$1.weight*$1.error*$1.error}
            var accepted = false
            for fraction in [1.0,0.5,0.25,0.125,0.0625] {
                var proposal = candidate
                for i in 1..<(n-1) {
                    let map = candidate[first+i].surface!,reference = original[first+i].surface!
                    var gains = map.channelEV,slopes = map.toneEV ?? Array(repeating:Float(0),count:count)
                    for node in 0..<count {
                        let change = coarseTerms(i*2*count+node).reduce(0.0) {sum,term in sum+(lookup[term.0].map {delta[$0]*fraction*term.1} ?? 0)}
                        for c in 0..<3 {gains[node*3+c] = Float(max(Double(reference.channelEV[node*3+c])-0.75*amount,min(Double(reference.channelEV[node*3+c])+0.75*amount,Double(gains[node*3+c])+change)))}
                        if toneFit {
                            let slopeChange = coarseTerms((i*2+1)*count+node).reduce(0.0) {sum,term in sum+(lookup[term.0].map {delta[$0]*fraction*term.1} ?? 0)}
                            slopes[node] = Float(max(Double(reference.toneEV?[node] ?? 0)-0.35*amount,min(Double(reference.toneEV?[node] ?? 0)+0.35*amount,Double(slopes[node])+slopeChange)))
                        }
                    }
                    proposal[first+i].surface = .init(width:map.width,height:map.height,channelEV:gains,guide:map.guide,rowModel:map.rowModel,toneEV:toneFit ? slopes : map.toneEV)
                }
                var error = 0.0,valid = true
                for m in measures {
                    guard let old = pulseAndTerms(m,original)?.0,let current = pulseAndTerms(m,candidate)?.0,let new = pulseAndTerms(m,proposal)?.0 else {valid = false;break}
                    let target = m.active ? old*(1-amount) : old
                    let weight = m.active ? 1.0 : 4.0
                    error += weight*pow(new-target,2)
                    if !m.active && abs(new-old) > 0.01 {valid = false}
                    if m.active && abs(new-target) > abs(current-target)+0.01 {valid = false}
                }
                if valid,error < oldError*0.99 {candidate = proposal;accepted = true;acceptedPasses += 1;break}
            }
            if !accepted {break}
        }
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        try encoder.encode(candidate).write(to:out.appendingPathComponent("spatial-fields.json"))
        for name in ["global-stops.json","settings.json","thumbnails.json"] {try FileManager.default.copyItem(at:folder.appendingPathComponent(name),to:out.appendingPathComponent(name))}
        var result:[[String:Any]] = []
        for m in measures {
            if let before = pulseAndTerms(m,original)?.0,let after = pulseAndTerms(m,candidate)?.0 {
                result.append(["event":first+m.event,"x":m.points[37].x/Double(width),"y":m.points[37].y/Double(height),"sourcePulse":m.sourcePulse,"before":before,"after":after,"active":m.active])
            }
        }
        let changed = original.indices.filter {original[$0].surface?.channelEV != candidate[$0].surface?.channelEV || original[$0].surface?.toneEV != candidate[$0].surface?.toneEV}
        let report:[String:Any] = ["changedFrames":changed,"acceptedPasses":acceptedPasses,"measurements":result,"rejections":rejections,"source":args[1],"input":folder.path,"amount":amount,"basisSpacing":spacing,"toneFit":toneFit,"limitation":"Experimental source-qualified native ROI field fit. Same-sign source pulses are not proof of unwanted flicker. Overlapping source support and held-output protection are not yet independently certified. No deployment permitted from fit residual alone."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("review.json"))
        // Export with original source PTS, independent of the nominal scene clock.
        if !changed.isEmpty {
            try await VideoEngine.export(asset:asset,curve:.init(times:allTimes,stops:stops,spatial:candidate),destination:out.appendingPathComponent("corrected.mp4"),progress:{_ in})
        }
        print("FINE_FIELD",measures.count,"active",measures.filter {$0.active}.count,"passes",acceptedPasses,"changed",changed)
    }
}
