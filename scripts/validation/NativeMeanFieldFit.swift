// Research regional radiance field fit. No shipping call site or image warp.
import Foundation
import AVFoundation
import CoreImage

@main struct NativeMeanFieldFit {
    struct Image:Decodable {let frame:Int;let pts:Double;let rgb:[Double];let positions:[[Double]]}
    struct Measurement:Decodable {let event:Int;let seed:[Int];let sourcePulse:Double;let guardMarginEV:Double;let active:Bool;let images:[Image]}
    struct Evidence:Decodable {let source:String;let first:Int;let endExclusive:Int;let measurements:[Measurement]}
    struct Pixel {let rgb:[Double];let x:Double;let y:Double;let weight:Double}
    struct Guard {let frames:[Int];let pixels:[[Pixel]];let centres:[[Double]];let baseline:Double}
    struct Equation {let terms:[(Int,Double)];let error:Double;let budget:Double;let weight:Double;let adjacent:Bool;let tolerance:Double}
    static let weights=[0.2126,0.7152,0.0722]
    static func light(_ rgb:[Double]) -> Double {zip(rgb,weights).reduce(0) {$0+$1.1*max(0,$1.0)}}
    struct Geometry {let texture:[Double];let energy:Double}
    static func descriptor(_ image:SpatialThumbnail,x:Double,y:Double,half:Int) -> Geometry? {
        guard x >= Double(half), y >= Double(half), x + Double(half) < Double(image.width-1), y + Double(half) < Double(image.height-1),
              image.rgb.count == image.width * image.height * 3 else { return nil }
        var values = [Double](), means = [Double](repeating: 0, count: 3)
        values.reserveCapacity((2*half+1)*(2*half+1)*3)
        let ix = Int(x),iy = Int(y),fx = x-Double(ix),fy = y-Double(iy)
        let interpolated = fx != 0 || fy != 0
        let count = Double((2 * half + 1) * (2 * half + 1))
        for dy in -half...half { for dx in -half...half {
            let p = ((iy+dy) * image.width + ix+dx) * 3
            for c in 0..<3 {
                let light: Double
                if interpolated {
                    let top = Double(image.rgb[p+c])*(1-fx)+Double(image.rgb[p+3+c])*fx
                    let bottom = Double(image.rgb[p+image.width*3+c])*(1-fx)+Double(image.rgb[p+image.width*3+3+c])*fx
                    light = top*(1-fy)+bottom*fy
                } else { light = Double(image.rgb[p+c]) }
                let v = log2(max(0.003,light))
                values.append(v); means[c] += v / count
            }
        } }
        // A slowly varying illumination gradient is approximately planar in
        // log light. Remove that plane for correspondence, but retain the raw
        // channel means for lighting measurement. This prevents a moving light
        // band from being mistaken for moving image texture.
        var slopeX = [Double](repeating: 0,count: 3), slopeY = slopeX
        var denominator = 0.0, index = 0
        for dy in -half...half { for dx in -half...half {
            denominator += Double(dx*dx)
            for c in 0..<3 {
                slopeX[c] += Double(dx)*(values[index]-means[c])
                slopeY[c] += Double(dy)*(values[index]-means[c]); index += 1
            }
        } }
        slopeX = slopeX.map { $0/max(1,denominator) }; slopeY = slopeY.map { $0/max(1,denominator) }
        var texture = [Double](); index = 0
        for dy in -half...half { for dx in -half...half { for c in 0..<3 {
            texture.append(values[index]-means[c]-Double(dx)*slopeX[c]-Double(dy)*slopeY[c]); index += 1
        } } }
        let energy = sqrt(texture.reduce(0) { $0 + $1 * $1 } / Double(texture.count))
        return Geometry(texture:texture,energy:energy)
    }
    static func main() async throws {
        let args=CommandLine.arguments
        guard args.count == 7,let amount=Double(args[4]),let spacing=Int(args[5]),(0...1).contains(amount),[2,4,8].contains(spacing),["tone","exposure"].contains(args[6]) else {throw VideoError.message("Usage: source-evidence.json baseline-folder fresh-output-folder amount spacing tone|exposure")}
        let decoder=JSONDecoder(),e=try decoder.decode(Evidence.self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
        let folder=URL(fileURLWithPath:args[2]),out=URL(fileURLWithPath:args[3])
        guard !FileManager.default.fileExists(atPath:out.path) else {throw VideoError.message("Fresh output required")}
        let original=try decoder.decode([SpatialField].self,from:Data(contentsOf:folder.appendingPathComponent("spatial-fields.json")))
        let stops=try decoder.decode([Double].self,from:Data(contentsOf:folder.appendingPathComponent("global-stops.json")))
        let thumbs=try decoder.decode([SpatialThumbnail].self,from:Data(contentsOf:folder.appendingPathComponent("thumbnails.json")))
        guard e.first >= 0,e.endExclusive <= original.count,stops.count == original.count,thumbs.count == stops.count,
              (e.first..<e.endExclusive).allSatisfy({original[$0].surface != nil && original[$0].surface?.rowModel != true}),
              let firstMap=original[e.first].surface,firstMap.width%spacing == 0,firstMap.height%spacing == 0 else {throw VideoError.message("Invalid retained fields")}
        let env=ProcessInfo.processInfo.environment
        let guardPhase=Int(env["FRANKLUMA_FIT_GUARD_PHASE"] ?? "10") ?? 10,guardStride=Int(env["FRANKLUMA_FIT_GUARD_STRIDE"] ?? "8") ?? 8
        let guardSlack=Double(env["FRANKLUMA_FIT_GUARD_SLACK"] ?? "0.001") ?? 0.001
        let frozenLead=Int(env["FRANKLUMA_FIT_FROZEN_LEAD"] ?? "1") ?? 1
        guard (6...12).contains(guardPhase),(2...8).contains(guardStride),(0...0.001).contains(guardSlack),(1...2).contains(frozenLead) else {throw VideoError.message("Invalid research controls")}
        let tone=args[6] == "tone",gw=firstMap.width/spacing,gh=firstMap.height/spacing,gc=gw*gh,mc=firstMap.width*firstMap.height
        var candidate=original,acceptedPasses=0,reviews=[[String:Any]]()
        // No active research source evidence means exact field passthrough.
        if amount > 0 && e.measurements.contains(where:{$0.active}) {
            let asset=AVURLAsset(url:URL(fileURLWithPath:e.source))
            guard let track=try await asset.loadTracks(withMediaType:.video).first else {throw VideoError.message("No video")}
            let preferred=try await track.load(.preferredTransform),natural=try await track.load(.naturalSize)
            let transform=VideoGeometry.coreImageTransform(preferred:preferred,naturalSize:natural)
            let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output);guard reader.startReading() else {throw reader.error ?? VideoError.message("Decode failed")}
            var images=[Int:CIImage](),pts=[Int:Double](),index=0
            while let sample=output.copyNextSampleBuffer() {
                defer {index += 1};if index >= e.endExclusive {break};if index < e.first {continue}
                guard let buffer=CMSampleBufferGetImageBuffer(sample) else {throw VideoError.message("Missing source frame")}
                let image=CIImage(cvPixelBuffer:buffer).transformed(by:transform)
                images[index]=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
                pts[index]=CMSampleBufferGetPresentationTimeStamp(sample).seconds
            }
            reader.cancelReading()
            guard images.count == e.endExclusive-e.first,e.measurements.flatMap(\.images).allSatisfy({abs((pts[$0.frame] ?? -1)-$0.pts) < 1e-8}) else {throw VideoError.message("Source PTS mismatch")}
            let linear=CGColorSpace(name:CGColorSpace.linearSRGB)!,context=CIContext(options:[.workingColorSpace:linear,.cacheIntermediates:false])
            func gpuThumbs(_ fields:[SpatialField]) -> [Int:SpatialThumbnail] {
                var result=[Int:SpatialThumbnail]()
                for frame in e.first..<e.endExclusive {
                    let image=SpatialRenderer.render(images[frame]!,global:stops[frame],field:fields[frame]),extent=image.extent
                    let small=image.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:56.0/extent.height,kCIInputAspectRatioKey:96.0/extent.width/(56.0/extent.height)])
                    var rgba=[Float](repeating:0,count:96*56*4)
                    rgba.withUnsafeMutableBytes {context.render(small,toBitmap:$0.baseAddress!,rowBytes:96*16,bounds:CGRect(x:0,y:0,width:96,height:56),format:.RGBAf,colorSpace:linear)}
                    var rgb=[Float](repeating:0,count:96*56*3)
                    for component in rgb.indices {rgb[component]=rgba[(component/3)*4+component%3]}
                    result[frame] = .init(width:96,height:56,rgb:rgb)
                }
                return result
            }
            func footprint(_ image:SpatialThumbnail,x:Double,y:Double) -> [Pixel] {
                let ix=Int(x),iy=Int(y),fx=x-Double(ix),fy=y-Double(iy)
                var pixels=[Pixel]()
                for dy in -6...6 {for dx in -6...6 {
                    for (ox,oy,weight) in [(0,0,(1-fx)*(1-fy)),(1,0,fx*(1-fy)),(0,1,(1-fx)*fy),(1,1,fx*fy)] where weight > 0 {
                        let px=min(image.width-1,ix+dx+ox),py=min(image.height-1,iy+dy+oy),p=(py*image.width+px)*3
                        pixels.append(.init(rgb:(0..<3).map {Double(image.rgb[p+$0])},x:(Double(px)+0.5)/Double(image.width),y:(Double(py)+0.5)/Double(image.height),weight:weight/169))
                    }
                }}
                return pixels
            }
            func plainLevel(_ pixels:[Pixel]) -> Double {log2(max(1e-9,pixels.reduce(0) {$0+light($1.rgb)*$1.weight}))}
            let baselineGPU=gpuThumbs(original)
            var guards=[Guard]()
            // A source-selected phase different from the retained encoded audit.
            // Frozen audit residuals are not loaded or optimised by this tool.
            for frame in e.first..<(e.endExclusive-1) {
                let a=thumbs[frame],b=thumbs[frame+1],camera=SurfaceMotion.estimate(SurfaceMotion.coarse(a),SurfaceMotion.coarse(b))
                let model=camera ?? SurfaceMotion.Model(x:[1,0,0],y:[0,1,0])
                for y in stride(from:guardPhase,to:a.height-6,by:guardStride) {for x in stride(from:guardPhase,to:a.width-6,by:guardStride) {
                    let q=model.point(Double(x),Double(y))
                    guard let da=descriptor(a,x:Double(x),y:Double(y),half:6),let db=descriptor(b,x:q.0,y:q.1,half:6),da.energy > 0.03,db.energy > 0.03 else {continue}
                    let correlation=zip(da.texture,db.texture).reduce(0) {$0+$1.0*$1.1}/(Double(da.texture.count)*da.energy*db.energy)
                    guard correlation > 0.95,q.0 >= 6,q.1 >= 6,q.0 < Double(b.width-6),q.1 < Double(b.height-6) else {continue}
                    let before=plainLevel(footprint(baselineGPU[frame]!,x:Double(x),y:Double(y))),after=plainLevel(footprint(baselineGPU[frame+1]!,x:q.0,y:q.1))
                    guards.append(.init(frames:[frame,frame+1],pixels:[footprint(a,x:Double(x),y:Double(y)),footprint(b,x:q.0,y:q.1)],centres:[[Double(x),Double(y)],[q.0,q.1]],baseline:after-before))
                }}
            }
            func coarse(_ frame:Int,_ node:Int,_ kind:Int) -> [(Int,Double)] {
                guard frame >= e.first+frozenLead,frame < e.endExclusive-1 else {return []}
                return SpatialRenderer.surfaceBasis(x:(Double(node%firstMap.width)+0.5)/Double(firstMap.width),y:(Double(node/firstMap.width)+0.5)/Double(firstMap.height),width:gw,height:gh).map {(((frame-e.first)*2+kind)*gc+$0.0,$0.1)}
            }
            func levelAndTerms(_ frame:Int,_ pixels:[Pixel],_ fields:[SpatialField]) -> (Double,[(Int,Double)]) {
                let map=fields[frame].surface!,global=stops[frame]+(fields[frame].brightnessEV ?? 0),epsilon=0.0001
                var sum=0.0,coefficients=[Int:Double]()
                for pixel in pixels {
                    let rendered=SpatialRenderer.surfaceRGB(pixel.rgb,x:pixel.x,y:pixel.y,map:map,global:global)
                    let value=light(rendered);sum += value*pixel.weight
                    let plus=light(SpatialRenderer.surfaceRGB(pixel.rgb,x:pixel.x,y:pixel.y,map:map,global:global+epsilon))
                    let minus=light(SpatialRenderer.surfaceRGB(pixel.rgb,x:pixel.x,y:pixel.y,map:map,global:global-epsilon))
                    let response=(plus-minus)/(2*epsilon*log(2.0))*pixel.weight
                    let basis=SpatialRenderer.surfaceBasis(x:pixel.x,y:pixel.y,width:map.width,height:map.height).map {node,weight -> (Int,Double) in
                        let difference=(0..<3).reduce(0.0) {$0+pow(log2(max(0.003,pixel.rgb[$1])/max(0.003,Double(map.guide[node*3+$1]))),2)}
                        return (node,weight*max(0.0001,exp(-difference/0.3)))
                    }
                    let total=basis.reduce(0) {$0+$1.1},feature=max(-3,min(2,log2(max(0.005,light(pixel.rgb))/0.18)))
                    for (node,weight) in basis {
                        for (key,w) in coarse(frame,node,0) {coefficients[key,default:0] += response*weight/total*w}
                        if tone {for (key,w) in coarse(frame,node,1) {coefficients[key,default:0] += response*weight/total*w*feature}}
                    }
                }
                return (log2(max(1e-9,sum)),coefficients.keys.sorted().map {($0,coefficients[$0]!/max(1e-9,sum))})
            }
            func nativePixels(_ image:Image) -> [Pixel] {(0..<25).map {i in .init(rgb:Array(image.rgb[(3*i)..<(3*i+3)]),x:image.positions[i][0],y:image.positions[i][1],weight:1.0/25)}}
            func nativePulse(_ m:Measurement,_ fields:[SpatialField]) -> (Double,[(Int,Double)]) {
                let alpha=(m.images[1].pts-m.images[0].pts)/(m.images[2].pts-m.images[0].pts),factors=[-(1-alpha),1.0,-alpha]
                var value=0.0,terms=[Int:Double]()
                for (image,factor) in zip(m.images,factors) {
                    let (level,gradient)=levelAndTerms(image.frame,nativePixels(image),fields);value += factor*level
                    for (key,c) in gradient {terms[key,default:0] += factor*c}
                }
                return (value,terms.keys.sorted().map {($0,terms[$0]!)})
            }
            let baselineNative=e.measurements.map {nativePulse($0,original).0}
            let baselineEnergy=guards.reduce(0.0) {$0+$1.baseline*$1.baseline}
            var cumulative=[Int:Double]()
            func guardSteps(_ fields:[SpatialField]) -> [Double] {
                let rendered=gpuThumbs(fields)
                return guards.map {g in plainLevel(footprint(rendered[g.frames[1]]!,x:g.centres[1][0],y:g.centres[1][1]))-plainLevel(footprint(rendered[g.frames[0]]!,x:g.centres[0][0],y:g.centres[0][1]))}
            }
            func objective(_ values:[Double]) -> Double {
                e.measurements.indices.filter {e.measurements[$0].active}.reduce(0.0) {sum,i in
                    let residual=max(0,abs(values[i]-baselineNative[i]*(1-amount))-e.measurements[i].guardMarginEV)
                    return sum+residual*residual
                }
            }
            func fields(_ values:[Int:Double]) -> [SpatialField] {
                var result=original
                for frame in (e.first+frozenLead)..<(e.endExclusive-1) {
                    let map=original[frame].surface!
                    var channels=map.channelEV,slopes=map.toneEV ?? [Float](repeating:0,count:mc)
                    for node in 0..<mc {
                        let ev=coarse(frame,node,0).reduce(0) {$0+(values[$1.0] ?? 0)*$1.1}
                        let slope=coarse(frame,node,1).reduce(0) {$0+(values[$1.0] ?? 0)*$1.1}
                        for c in 0..<3 {channels[node*3+c] += Float(ev)}
                        slopes[node] += Float(slope)
                    }
                    result[frame].surface = .init(width:map.width,height:map.height,channelEV:channels,guide:map.guide,rowModel:map.rowModel,toneEV:tone ? slopes:map.toneEV)
                }
                return result
            }
            for pass in 0..<4 {
                let currentNative=e.measurements.map {nativePulse($0,candidate).0},currentSteps=guardSteps(candidate)
                var equations=[Equation]()
                for i in e.measurements.indices {
                    let m=e.measurements[i],pulse=nativePulse(m,candidate),error=pulse.0-(m.active ? baselineNative[i]*(1-amount):baselineNative[i])
                    if !pulse.1.isEmpty {equations.append(.init(terms:pulse.1,error:error,budget:max(abs(error),m.active ? abs(baselineNative[i])*amount+0.01:0.01),weight:m.active ? 12:4,adjacent:false,tolerance:m.active ? m.guardMarginEV:0))}
                }
                for (i,g) in guards.enumerated() {
                    var terms=[Int:Double]()
                    for j in 0..<2 {for (key,value) in levelAndTerms(g.frames[j],g.pixels[j],candidate).1 {terms[key,default:0] += (j == 0 ? -1:1)*value}}
                    if !terms.isEmpty {equations.append(.init(terms:terms.keys.sorted().map {($0,terms[$0]!)},error:currentSteps[i],budget:max(abs(currentSteps[i]),abs(g.baseline)+guardSlack),weight:0.2,adjacent:true,tolerance:0))}
                }
                let keys=Array(Set(equations.flatMap {$0.terms.map(\.0)})).sorted(),lookup=Dictionary(uniqueKeysWithValues:keys.enumerated().map {($1,$0)})
                let rows=equations.map {r in PulseReconstruction.FieldRow(terms:r.terms.map {(lookup[$0.0]!,$0.1)},error:r.error,budget:r.budget,weight:r.weight,adjacent:r.adjacent,objectiveTolerance:r.tolerance)}
                let bounds=keys.map {key -> (Double,Double) in let limit=Double((key/gc)%2 == 0 ? 0.75:0.35)*amount,used=cumulative[key] ?? 0;return (-limit-used,limit-used)}
                guard let solution=PulseReconstruction.solveBoundedField(rows:rows,bounds:bounds,regularization:0.02,maximumIterations:600,restoreFeasibility:true,convergenceTolerance:1e-6) else {throw VideoError.message("Invalid regional solve")}
                let before=objective(currentNative)
                var accepted=false
                for fraction in [1.0,0.5,0.25,0.125,0.0625,0.03125] {
                    var proposed=cumulative
                    for (i,key) in keys.enumerated() {proposed[key,default:0] += fraction*solution.increments[i]}
                    let trial=fields(proposed),values=e.measurements.map {nativePulse($0,trial).0},steps=guardSteps(trial),after=objective(values)
                    let protected=e.measurements.indices.allSatisfy {e.measurements[$0].active || abs(values[$0]-baselineNative[$0]) <= 0.01001}
                    let guardOK=guards.indices.allSatisfy {abs(steps[$0]) <= abs(guards[$0].baseline)+guardSlack+0.00001} && steps.reduce(0.0) {$0+$1*$1} <= baselineEnergy+1e-8
                    print("TRIAL",pass,fraction,"objective",after,"protected",protected,"guard",guardOK,"maxGuardExcess",guards.indices.map {abs(steps[$0])-abs(guards[$0].baseline)-guardSlack}.max() ?? 0)
                    if protected && guardOK && after < before*0.999 {
                        candidate=trial;cumulative=proposed;acceptedPasses += 1;accepted=true
                        reviews.append(["pass":pass,"fraction":fraction,"before":before,"after":after,"iterations":solution.iterations,"feasibilityScale":solution.feasibilityScale,"guardEnergy":steps.reduce(0.0) {$0+$1*$1}])
                        print("ACCEPTED",pass,fraction,before,after);break
                    }
                }
                if !accepted {reviews.append(["pass":pass,"accepted":false,"objective":before,"feasibilityScale":solution.feasibilityScale]);break}
            }
            let finalNative=e.measurements.map {nativePulse($0,candidate).0}
            reviews.append(["nativeMeasurements":e.measurements.indices.map {i in ["event":e.measurements[i].event,"seed":e.measurements[i].seed,"active":e.measurements[i].active,"before":baselineNative[i],"after":finalNative[i]] as [String:Any]},"guardCount":guards.count,"baselineGuardEnergy":baselineEnergy])
        }
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let encoder=JSONEncoder()
        try encoder.encode(candidate).write(to:out.appendingPathComponent("spatial-fields.json"))
        try encoder.encode(stops).write(to:out.appendingPathComponent("global-stops.json"))
        for name in ["thumbnails.json","settings.json"] {let path=folder.appendingPathComponent(name);if FileManager.default.fileExists(atPath:path.path) {try FileManager.default.copyItem(at:path,to:out.appendingPathComponent(name))}}
        try JSONSerialization.data(withJSONObject:["source":e.source,"amount":amount,"spacing":spacing,"tone":tone,"guardPhase":guardPhase,"guardStride":guardStride,"guardSlackEV":guardSlack,"frozenLead":frozenLead,"acceptedPasses":acceptedPasses,"reviews":reviews],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("review.json"))
        print("FITTED",acceptedPasses,out.path)
    }
}
