// Source-only verification on disjoint native geometry and photometry footprints.
// No pixel warp, field fit or automatic correction call site.
import Foundation
import AVFoundation
import CoreImage

@main struct NativeDisjointSupportAudit {
    struct History:Decodable {let frame:Int;let analysisX:Double;let analysisY:Double}
    struct Probe:Decodable {let analysisX:Int;let analysisY:Int;let history:[History]?}
    struct Diagnostic:Decodable {let source:String;let first:Int;let endExclusive:Int;let analysisWidth:Int;let analysisHeight:Int;let times:[Double];let diagnosticRows:[Probe]}
    struct Samples {let ring:[[Double]];let gradients:[[Double]];let meter:[Double];let invalidMeterPixels:Int}
    // Geometry-only gradient orientations: positive exposure/contrast scaling
    // cancels, while two independent edge directions and strong native signal
    // are required. This does not certify colour or lighting correspondence.
    static func edgeSimilarity(_ a:[[Double]],_ b:[[Double]]) -> Double? {
        guard a.count == b.count else {return nil}
        var cosines=[Double](),xx=0.0,xy=0.0,yy=0.0,sourceEdges=0
        for i in a.indices {
            guard a[i].count == 2,b[i].count == 2,a[i].allSatisfy(\.isFinite) else {continue}
            let am=hypot(a[i][0],a[i][1]);guard am >= 0.003 else {continue}
            sourceEdges += 1
            guard b[i].allSatisfy(\.isFinite) else {continue}
            let bm=hypot(b[i][0],b[i][1]);guard bm >= 0.003,(0.25...4).contains(bm/am) else {continue}
            let gx=a[i][0]/am,gy=a[i][1]/am
            xx += gx*gx;xy += gx*gy;yy += gy*gy
            cosines.append((a[i][0]*b[i][0]+a[i][1]*b[i][1])/(am*bm))
        }
        guard cosines.count >= 32,cosines.count*10 >= sourceEdges*7 else {return nil}
        let n=Double(cosines.count),minimumEigenvalue=(xx+yy-sqrt(pow(xx-yy,2)+4*xy*xy))/(2*n)
        guard minimumEigenvalue >= 0.1 else {return nil}
        guard cosines.filter({$0 >= 0.9}).count*20 >= cosines.count*19 else {return 0}
        return cosines.reduce(0,+)/n
    }
    // Geometry-only luminance shape. RGB identity and illumination remain
    // unproven even when the printed luminance pattern agrees.
    static func luminanceSimilarity(_ a:[[Double]],_ b:[[Double]]) -> Double? {
        guard a.count == b.count,a.count >= 32 else {return nil}
        let valid=a.indices.filter {i in a[i].count == 3 && b[i].count == 3 && (a[i]+b[i]).allSatisfy {$0.isFinite && $0 >= 0 && $0 < 0.95}}
        guard valid.count >= 32,valid.count*4 >= a.count*3 else {return nil}
        func y(_ rgb:[Double]) -> Double {0.2126*rgb[0]+0.7152*rgb[1]+0.0722*rgb[2]}
        let x=valid.map {y(a[$0])},z=valid.map {y(b[$0])}
        let mx=x.reduce(0,+)/Double(x.count),mz=z.reduce(0,+)/Double(z.count)
        let vx=x.reduce(0) {$0+pow($1-mx,2)},vz=z.reduce(0) {$0+pow($1-mz,2)}
        guard vx/Double(x.count) > 1e-6,vz/Double(z.count) > 1e-6,(0.25...4).contains(sqrt(vz/vx)) else {return nil}
        return zip(x,z).reduce(0) {$0+($1.0-mx)*($1.1-mz)}/sqrt(vx*vz)
    }

    static func nativePixel(_ raster:[Float],width nw:Int,height nh:Int,x:Double,y:Double) -> [Double]? {
                let ix=Int(floor(x)),iy=Int(floor(y)),fx=x-Double(ix),fy=y-Double(iy)
                guard ix >= 0,iy >= 0,ix+1 < nw,iy+1 < nh else {return nil}
                return (0..<3).map {c in
                    let p=(iy*nw+ix)*4+c
                    // Check every contributing native pixel before interpolation:
                    // clipping must not disappear inside a fractional sample.
                    let indices=[p,p+4,p+nw*4,p+nw*4+4]
                    let weights=[(1-fx)*(1-fy),fx*(1-fy),(1-fx)*fy,fx*fy]
                    for (q,weight) in zip(indices,weights) where weight > 0 {
                        let value=Double(raster[q])
                        if !value.isFinite || value < 0 || value >= 0.95 {return Double.nan}
                    }
                    let a=Double(raster[p])*(1-fx)+Double(raster[p+4])*fx
                    let b=Double(raster[p+nw*4])*(1-fx)+Double(raster[p+nw*4+4])*fx
                    return a*(1-fy)+b*fy
                }
            }

    static func geometryPixel(_ raster:[Float],width:Int,height:Int,x:Double,y:Double,half:Int) -> [Double]? {
        var sum=[Double](repeating:0,count:3)
        for dy in -half...half {for dx in -half...half {
            guard let rgb=nativePixel(raster,width:width,height:height,x:x+Double(dx),y:y+Double(dy)) else {return nil}
            // No invalid native contributor may be hidden by geometry averaging.
            guard rgb.allSatisfy({$0.isFinite && $0 >= 0 && $0 < 0.95}) else {return [Double.nan,Double.nan,Double.nan]}
            for c in 0..<3 {sum[c] += rgb[c]}
        }}
        let count=Double((2*half+1)*(2*half+1))
        return sum.map {$0/count}
    }

    // Spatial deletion and location sensitivity are observable diagnostics, not
    // independent sensor-noise estimates: printed texture and codec correlation
    // invalidate an IID standard error derived from these pixels.
    static func meterSensitivity(_ options:[Samples],center:Int) -> [String:Any] {
        func ys(_ sample:Samples) -> [Double]? {
            guard sample.invalidMeterPixels == 0,sample.meter.count == 75,
                  sample.meter.allSatisfy({$0.isFinite && $0 >= 0 && $0 < 0.95}) else {return nil}
            return (0..<25).map {i in 0.2126*sample.meter[3*i]+0.7152*sample.meter[3*i+1]+0.0722*sample.meter[3*i+2]}
        }
        guard let y=ys(options[center]) else {return ["available":false]}
        let mean=y.reduce(0,+)/25
        guard mean > 0 else {return ["available":false]}
        let rowDeletion=(0..<5).map {row in y.enumerated().filter {$0.offset/5 != row}.map(\.element).reduce(0,+)/20}
        let columnDeletion=(0..<5).map {col in y.enumerated().filter {$0.offset%5 != col}.map(\.element).reduce(0,+)/20}
        let shifted=options.compactMap {ys($0).map {$0.reduce(0,+)/25}}.filter {$0 > 0}
        let deletion=rowDeletion+columnDeletion
        return ["available":true,"meanY":mean,"minimumTileY":y.min()!,
                "darkTileCount":y.filter {$0 <= 0.005}.count,
                "validLocationCount":shifted.count,
                "locationRangeEV":shifted.map {log2($0/mean)}.max()!-shifted.map {log2($0/mean)}.min()!,
                "maximumSpatialDeletionEV":deletion.allSatisfy({$0 > 0}) ? deletion.map {abs(log2($0/mean))}.max()! as Any : NSNull(),
                "zeroRadianceDeletionCount":deletion.filter {$0 <= 0}.count,
                "limitation":"Spatial heterogeneity and ±3 native-pixel location sensitivity; not sensor noise, a confidence interval, or correction qualification."]
    }

    // Equal native displacement in each frame is a sensitivity stress test.
    // These offsets are not independently allowed geometry/noise bounds.
    static func pulseLocationSensitivity(_ a:[Samples],_ b:[Samples],_ c:[Samples],alpha:Double,center:Int) -> [String:Any] {
        func mean(_ sample:Samples) -> Double? {
            guard sample.invalidMeterPixels == 0,sample.meter.count == 75,
                  sample.meter.allSatisfy({$0.isFinite && $0 >= 0 && $0 < 0.95}) else {return nil}
            let value=(0..<25).reduce(0.0) {sum,i in
                sum+0.2126*sample.meter[3*i]+0.7152*sample.meter[3*i+1]+0.0722*sample.meter[3*i+2]
            }/25
            return value > 0 ? value : nil
        }
        guard a.count == b.count,b.count == c.count,(0...1).contains(alpha) else {return ["available":false]}
        let values=a.indices.map {i -> Double? in
            guard let before=mean(a[i]),let middle=mean(b[i]),let after=mean(c[i]) else {return nil}
            return log2(middle/((1-alpha)*before+alpha*after))
        }
        guard let nominal=values[center] else {return ["available":false]}
        let valid=values.compactMap {$0}
        return ["available":true,"validLocationCount":valid.count,"nominalExcursionEV":nominal,
                "locationExcursionRangeEV":valid.max()!-valid.min()!,
                "maximumChangeFromNominalEV":valid.map {abs($0-nominal)}.max()!,
                "limitation":"Arithmetic-radiance temporal excursion under identical ±3 native-pixel offsets, not geometry-certified alternatives, noise bounds, or qualified illumination."]
    }

    static func main() async throws {
        let args=CommandLine.arguments
        if args.count == 2,args[1] == "self-test" {
            let pattern=(0..<120).map {i in let v=0.02+0.01*sin(Double(i));return [v,v,v]}
            guard abs(luminanceSimilarity(pattern,pattern.map {$0.map {$0*2+0.01}})!-1) < 1e-12,
                  luminanceSimilarity(pattern,Array(repeating:[0.01,0.01,0.01],count:120)) == nil,
                  luminanceSimilarity(pattern,pattern.reversed())! < 0.995 else {throw VideoError.message("Luminance geometry self-test failed")}
            let gradients=(0..<120).map {i in [0.01*cos(Double(i)),0.01*sin(Double(i))]}
            guard let scaled=edgeSimilarity(gradients,gradients.map {$0.map {$0*2}}),abs(scaled-1) < 1e-12,
                  edgeSimilarity(gradients,gradients.map {[-$0[1],$0[0]]})! < 0.99,
                  edgeSimilarity(Array(repeating:[0.01,0],count:120),Array(repeating:[0.02,0],count:120)) == nil,
                  edgeSimilarity(gradients,Array(repeating:[0,0],count:120)) == nil else {throw VideoError.message("Edge geometry self-test failed")}
            let clipped:[Float]=[1,1,1,1, 0.1,0.1,0.1,1, 0.1,0.1,0.1,1, 0.1,0.1,0.1,1]
            let zeroWeightClipped:[Float]=[0.1,0.1,0.1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1]
            guard nativePixel(clipped,width:2,height:2,x:0.5,y:0.5)!.allSatisfy({!$0.isFinite}),
                  nativePixel(zeroWeightClipped,width:2,height:2,x:0,y:0)!.allSatisfy({$0.isFinite && abs($0-0.1) < 1e-7}),
                  nativePixel(clipped,width:2,height:2,x:-1,y:0) == nil else {throw VideoError.message("Native clipping self-test failed")}
            var averagingRaster=[Float](repeating:0.1,count:9*9*4)
            guard geometryPixel(averagingRaster,width:9,height:9,x:4,y:4,half:2)!.allSatisfy({abs($0-0.1) < 1e-7}) else {throw VideoError.message("Geometry averaging self-test failed")}
            averagingRaster[(4*9+4)*4]=1
            guard geometryPixel(averagingRaster,width:9,height:9,x:4,y:4,half:2)!.allSatisfy({!$0.isFinite}),
                  geometryPixel(averagingRaster,width:9,height:9,x:0,y:0,half:2) == nil else {throw VideoError.message("Geometry averaging clipping/bounds self-test failed")}
            func textureRaster(shift:Int,exposure:Double,noise:Double,replaced:Bool=false) -> [Float] {
                (0..<(64*64)).flatMap {p -> [Float] in
                    let x=Double(p%64-shift),y=Double(p/64)
                    let texture=replaced ? sin(x*0.33)*cos(y*0.12) : sin(x*0.18)*cos(y*0.20)
                    let value=Float(exposure*(0.03+0.01*texture)+noise*(p%2 == 0 ? 1 : -1))
                    return [value,value,value,1]
                }
            }
            let originalTexture=textureRaster(shift:0,exposure:1,noise:0)
            let noisyTexture=textureRaster(shift:0,exposure:1.02,noise:0.002)
            let movedTexture=textureRaster(shift:3,exposure:1.02,noise:0.002)
            let replacedTexture=textureRaster(shift:0,exposure:1.02,noise:0.002,replaced:true)
            let testPoints=stride(from:10,through:50,by:5).flatMap {y in stride(from:10,through:50,by:5).map {x in (x,y)}}
            func sampledTexture(_ raster:[Float],half:Int,shift:Int=0) -> [[Double]] {
                testPoints.map {geometryPixel(raster,width:64,height:64,x:Double($0.0+shift),y:Double($0.1),half:half)!}
            }
            let originalAverage=sampledTexture(originalTexture,half:2)
            guard luminanceSimilarity(sampledTexture(originalTexture,half:0),sampledTexture(noisyTexture,half:0))! < 0.995,
                  luminanceSimilarity(originalAverage,sampledTexture(noisyTexture,half:2))! >= 0.995,
                  luminanceSimilarity(originalAverage,sampledTexture(movedTexture,half:2))! < 0.995,
                  luminanceSimilarity(originalAverage,sampledTexture(movedTexture,half:2,shift:3))! >= 0.995,
                  luminanceSimilarity(originalAverage,sampledTexture(replacedTexture,half:2))! < 0.995 else {throw VideoError.message("Averaged geometry motion/noise/replacement self-test failed")}
            let flat=Samples(ring:[],gradients:[],meter:Array(repeating:0.01,count:75),invalidMeterPixels:0)
            let flatSensitivity=meterSensitivity(Array(repeating:flat,count:49),center:24)
            guard flatSensitivity["locationRangeEV"] as? Double == 0,
                  abs(flatSensitivity["maximumSpatialDeletionEV"] as! Double) < 1e-12 else {throw VideoError.message("Meter sensitivity self-test failed")}
            var patterned=flat.meter;for i in 0..<5 {for c in 0..<3 {patterned[3*i+c]=0.002}}
            let dark=Samples(ring:[],gradients:[],meter:patterned,invalidMeterPixels:0)
            let darkSensitivity=meterSensitivity([dark],center:0)
            guard darkSensitivity["darkTileCount"] as? Int == 5,
                  (darkSensitivity["maximumSpatialDeletionEV"] as! Double) > 0.2 else {throw VideoError.message("Dark spatial sensitivity self-test failed")}
            let bright=Samples(ring:[],gradients:[],meter:flat.meter.map {$0*1.5},invalidMeterPixels:0)
            let pulseSensitivity=pulseLocationSensitivity([flat,flat],[bright,bright],[flat,flat],alpha:0.5,center:0)
            guard abs((pulseSensitivity["nominalExcursionEV"] as! Double)-log2(1.5)) < 1e-12,
                  pulseSensitivity["maximumChangeFromNominalEV"] as? Double == 0 else {throw VideoError.message("Temporal sensitivity self-test failed")}
            let invalid=Samples(ring:[],gradients:[],meter:flat.meter,invalidMeterPixels:1)
            guard meterSensitivity([invalid],center:0)["available"] as? Bool == false else {throw VideoError.message("Invalid sensitivity self-test failed")}
            print("EDGE_GEOMETRY_NATIVE_CLIPPING_AND_SENSITIVITY_SELF_TEST_PASS");return
        }
        guard args.count == 3 else {throw VideoError.message("Usage: source-diagnostic.json fresh-report.json")}
        let diagnostic=try JSONDecoder().decode(Diagnostic.self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
        let out=URL(fileURLWithPath:args[2])
        guard !FileManager.default.fileExists(atPath:out.path) else {throw VideoError.message("Fresh report required")}
        let refineMeters=ProcessInfo.processInfo.environment["FRANKLUMA_NATIVE_REFINED_METER"] == "1"
        let exportMeters=ProcessInfo.processInfo.environment["FRANKLUMA_NATIVE_METER_EXPORT"] == "1"
        let edgeGeometry=ProcessInfo.processInfo.environment["FRANKLUMA_NATIVE_EDGE_GEOMETRY"] == "1"
        let luminanceGeometry=ProcessInfo.processInfo.environment["FRANKLUMA_NATIVE_LUMA_GEOMETRY"] == "1"
        guard !refineMeters || (exportMeters && luminanceGeometry) else {throw VideoError.message("Refined meter diagnostic requires RGB export and luminance geometry")}
        let geometryThreshold=luminanceGeometry ? 0.995 : (edgeGeometry ? 0.99 : 0.995)
        let boxGeometry=ProcessInfo.processInfo.environment["FRANKLUMA_NATIVE_EDGE_BOX"] == "1"
        let broadGeometry=ProcessInfo.processInfo.environment["FRANKLUMA_NATIVE_BROAD_LANDMARKS"] == "1"
        let ringRadius=broadGeometry ? 70 : 35,ringStride=broadGeometry ? 6 : 3
        let geometryAverageHalf=Int(ProcessInfo.processInfo.environment["FRANKLUMA_NATIVE_GEOMETRY_AVERAGE_HALF"] ?? "0") ?? -1
        guard [0,2].contains(geometryAverageHalf),geometryAverageHalf == 0 || luminanceGeometry else {throw VideoError.message("Geometry averaging must be half 0 or 2 and requires luminance geometry")}
        let supportExtent=Double(ringRadius)+(boxGeometry ? 7 : 3)+Double(geometryAverageHalf)
        // A source-grid phase, independent of corrected-output residual ranking.
        // Spacing 32 analysis pixels keeps native 71-pixel supports separated.
        let seedSpacing=Int(ProcessInfo.processInfo.environment["FRANKLUMA_NATIVE_SEED_SPACING"] ?? "32") ?? 0
        guard [24,32].contains(seedSpacing) else {throw VideoError.message("Seed spacing must be 24 or 32")}
        let probes=diagnostic.diagnosticRows.filter {p in
            p.analysisX%seedSpacing == 15 && p.analysisY%seedSpacing == 15 && (p.history?.count ?? 0) >= 4
        }
        guard !probes.isEmpty else {throw VideoError.message("No source probes in fixed phase")}
        let asset=AVURLAsset(url:URL(fileURLWithPath:diagnostic.source))
        guard let track=try await asset.loadTracks(withMediaType:.video).first else {throw VideoError.message("No video")}
        let preferred=try await track.load(.preferredTransform),natural=try await track.load(.naturalSize)
        let transform=VideoGeometry.coreImageTransform(preferred:preferred,naturalSize:natural)
        let reader=try AVAssetReader(asset:asset),output=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output);guard reader.startReading() else {throw reader.error ?? VideoError.message("Decode failed")}
        defer {reader.cancelReading()}
        let linear=CGColorSpace(name:CGColorSpace.linearSRGB)!,context=CIContext(options:[.workingColorSpace:linear,.cacheIntermediates:false])
        var stored=[Int:[Int:[Samples]]](),times=[Int:Double](),nativeSize=[Int](),index=0
        let offsets=(-3...3).flatMap {dy in (-3...3).map {dx in (dx,dy)}}
        let ring=(-ringRadius...ringRadius).filter {$0%ringStride == 0}.flatMap {dy in
            (-ringRadius...ringRadius).filter {$0%ringStride == 0 && max(abs($0),abs(dy)) >= (boxGeometry ? 21 : 18)}.map {dx in (dx,dy)}
        }
        while let sample=output.copyNextSampleBuffer() {
            defer {index += 1};if index >= diagnostic.endExclusive {break};if index < diagnostic.first {continue}
            guard let buffer=CMSampleBufferGetImageBuffer(sample) else {throw VideoError.message("No raster")}
            let image=CIImage(cvPixelBuffer:buffer).transformed(by:transform),extent=image.extent
            let nw=Int(extent.width.rounded()),nh=Int(extent.height.rounded());nativeSize=[nw,nh]
            guard nw*nh <= 40_000_000 else {throw VideoError.message("Raster budget exceeded")}
            var raster=[Float](repeating:0,count:nw*nh*4)
            raster.withUnsafeMutableBytes {context.render(image.transformed(by:CGAffineTransform(translationX:-extent.minX,y:-extent.minY)),toBitmap:$0.baseAddress!,rowBytes:nw*16,bounds:CGRect(x:0,y:0,width:nw,height:nh),format:.RGBAf,colorSpace:linear)}
            func pixel(_ x:Double,_ y:Double) -> [Double]? {
                nativePixel(raster,width:nw,height:nh,x:x,y:y)
            }
            for (pi,probe) in probes.enumerated() {
                guard let point=probe.history?.first(where:{$0.frame == index}) else {continue}
                let cx=(point.analysisX+0.5)*Double(nw)/Double(diagnostic.analysisWidth)-0.5
                let cy=(point.analysisY+0.5)*Double(nh)/Double(diagnostic.analysisHeight)-0.5
                var options=[Samples]()
                for (dx,dy) in offsets {
                    let geometry=ring.compactMap {geometryPixel(raster,width:nw,height:nh,x:cx+Double($0.0+dx),y:cy+Double($0.1+dy),half:geometryAverageHalf)}
                    let gradients=ring.map {point -> [Double] in
                        let x=cx+Double(point.0+dx),y=cy+Double(point.1+dy)
                        let radiance: (Double,Double) -> Double? = { xx,yy in
                            var sum=0.0,count=0
                            let half=boxGeometry ? 1 : 0
                            for oy in -half...half {for ox in -half...half {
                                guard let rgb=pixel(xx+Double(ox),yy+Double(oy)),
                                      rgb.allSatisfy({$0.isFinite && $0 >= 0 && $0 < 0.95}) else {return nil}
                                sum += 0.2126*rgb[0]+0.7152*rgb[1]+0.0722*rgb[2];count += 1
                            }}
                            return sum/Double(count)
                        }
                        let step=boxGeometry ? 3.0 : 1.0
                        guard let l=radiance(x-step,y),let r=radiance(x+step,y),
                              let t=radiance(x,y-step),let b=radiance(x,y+step) else {return [Double.nan,Double.nan]}
                        return [(r-l)/(2*step),(b-t)/(2*step)]
                    }
                    var meter=[Double](),invalid=0
                    for ty in -2...2 {for tx in -2...2 {
                        var sum=[Double](repeating:0,count:3),count=0
                        for yy in -2...2 {for xx in -2...2 {
                            guard let rgb=pixel(cx+Double(tx*5+xx+dx),cy+Double(ty*5+yy+dy)) else {continue}
                            if rgb.contains(where:{!$0.isFinite || $0 < 0 || $0 >= 0.95}) {invalid += 1}
                            for c in 0..<3 {sum[c] += rgb[c]};count += 1
                        }}
                        if count == 25 {meter += sum.map {$0/25}}
                    }}
                    options.append(.init(ring:geometry.count == ring.count ? geometry : [],gradients:gradients,meter:meter,invalidMeterPixels:invalid))
                }
                stored[pi,default:[:]][index]=options
            }
            times[index]=CMSampleBufferGetPresentationTimeStamp(sample).seconds
        }
        guard times.count == diagnostic.endExclusive-diagnostic.first,
              diagnostic.times.count == times.count,
              diagnostic.times.enumerated().allSatisfy({abs((times[diagnostic.first+$0.offset] ?? -1)-$0.element) < 1e-8}) else {
            throw VideoError.message("Incomplete source interval or source PTS mismatch")
        }
        // Exclude clipping with a shared pair mask. Never clamp radiance.
        func colorSimilarity(_ a:[[Double]],_ b:[[Double]]) -> Double? {
            guard a.count == ring.count,b.count == ring.count else {return nil}
            let valid=a.indices.filter {i in (a[i]+b[i]).allSatisfy {$0.isFinite && $0 >= 0 && $0 < 0.95}}
            guard valid.count*4 >= ring.count*3 else {return nil}
            var correlations=[Double]()
            for c in 0..<3 {
                let x=valid.map {a[$0][c]},y=valid.map {b[$0][c]},mx=x.reduce(0,+)/Double(x.count),my=y.reduce(0,+)/Double(y.count)
                let vx=x.reduce(0) {$0+pow($1-mx,2)},vy=y.reduce(0) {$0+pow($1-my,2)}
                guard vx/Double(x.count) > 1e-6,vy/Double(y.count) > 1e-6 else {return nil}
                correlations.append(zip(x,y).reduce(0) {$0+($1.0-mx)*($1.1-my)}/sqrt(vx*vy))
            }
            return correlations.min()
        }
        func similarity(_ a:Samples,_ b:Samples) -> Double? {
            if luminanceGeometry {return luminanceSimilarity(a.ring,b.ring)}
            return edgeGeometry ? edgeSimilarity(a.gradients,b.gradients) : colorSimilarity(a.ring,b.ring)
        }
        let center=offsets.firstIndex(where:{$0 == (0,0)})!
        var reports=[[String:Any]](),counts=[String:Int]()
        var retainedBounds=[[Double]](),overlapping=0,boundary=0
        for (pi,probe) in probes.enumerated() {
            // Certify separation using each trajectory's complete native support
            // envelope, including every ±3-pixel search and bilinear neighbor.
            let points=probe.history!.map {point in
                ((point.analysisX+0.5)*Double(nativeSize[0])/Double(diagnostic.analysisWidth)-0.5,
                 (point.analysisY+0.5)*Double(nativeSize[1])/Double(diagnostic.analysisHeight)-0.5)
            }
            let bounds=[points.map {$0.0}.min()!-supportExtent,points.map {$0.1}.min()!-supportExtent,
                        points.map {$0.0}.max()!+supportExtent,points.map {$0.1}.max()!+supportExtent]
            if bounds[0] < 0 || bounds[1] < 0 || bounds[2] >= Double(nativeSize[0]) || bounds[3] >= Double(nativeSize[1]) {
                boundary += 1;continue
            }
            if retainedBounds.contains(where:{b in bounds[0] <= b[2] && bounds[2] >= b[0] && bounds[1] <= b[3] && bounds[3] >= b[1]}) {
                overlapping += 1;continue
            }
            retainedBounds.append(bounds)
            let available=(stored[pi] ?? [:]).keys.sorted()
            var checks=[[String:Any]](),qualified=[Int:Samples]()
            for frame in available {qualified[frame]=stored[pi]![frame]![center]}
            for pair in zip(available,available.dropFirst()) where pair.1 == pair.0+1 {
                let a=stored[pi]![pair.0]!,b=stored[pi]![pair.1]!
                let scores=b.enumerated().compactMap {i,v in similarity(a[center],v).map {(i,$0)}}.sorted {$0.1 > $1.1}
                var row:[String:Any]=["frames":[pair.0,pair.1]],reason="nativeGeometryUnavailable"
                if let best=scores.first {
                    let reverse=a.enumerated().compactMap {i,v in similarity(b[best.0],v).map {(i,$0)}}.sorted {$0.1 > $1.1}
                    row["geometryScore"]=best.1;row["nominalRGBMinCorrelation"]=colorSimilarity(a[center].ring,b[center].ring) as Any? ?? NSNull();row["refinementPixels"]=[offsets[best.0].0,offsets[best.0].1]
                    if best.1 < geometryThreshold {reason="nativeGeometryShape"}
                    else if let back=reverse.first,back.1 >= geometryThreshold,hypot(Double(offsets[back.0].0),Double(offsets[back.0].1)) <= 1 {
                        // The unrefined transported locations must themselves pass.
                        // A diagnostic search must not silently alter photometry.
                        if let nominal=similarity(a[center],b[center]),nominal >= geometryThreshold {reason="accepted"}
                        else {reason="nativeRefinementRequired"}
                    } else {reason="nativeReciprocalPosition"}
                }
                row["reason"]=reason;counts[reason,default:0] += 1;checks.append(row)
            }
            var pulses=[[String:Any]](),temporalSensitivity=[[String:Any]](),refinedBrackets=[[String:Any]]()
            for event in available where qualified[event-1] != nil && qualified[event+1] != nil {
                let a=qualified[event-1]!,b=qualified[event]!,c=qualified[event+1]!
                if refineMeters {
                    let before=stored[pi]![event-1]!,middle=stored[pi]![event]!,after=stored[pi]![event+1]!
                    func peak(_ source:Samples,_ candidates:[Samples]) -> (Int,Double)? {
                        candidates.enumerated().compactMap {i,v in similarity(source,v).map {(i,$0)}}.sorted {$0.1 > $1.1}.first
                    }
                    var refined:[String:Any]=["event":event,"pts":[times[event-1]!,times[event]!,times[event+1]!],"geometryQualified":false,"rejection":"nativeRefinedGeometryUnavailable"]
                    if let left=peak(middle[center],before),let right=peak(middle[center],after) {
                        let backLeft=peak(before[left.0],middle),backRight=peak(after[right.0],middle)
                        let across=peak(before[left.0],after),backAcross=peak(after[right.0],before)
                        refined["neighborGeometryScores"]=[left.1,right.1]
                        refined["nativeOffsets"]=[[offsets[left.0].0,offsets[left.0].1],[0,0],[offsets[right.0].0,offsets[right.0].1]]
                        func close(_ index:Int,_ target:Int) -> Bool {hypot(Double(offsets[index].0-offsets[target].0),Double(offsets[index].1-offsets[target].1)) <= 1}
                        let interiors=[left.0,right.0].allSatisfy {abs(offsets[$0].0) < 3 && abs(offsets[$0].1) < 3}
                        let reciprocal=backLeft.map {$0.1 >= geometryThreshold && close($0.0,center)} == true && backRight.map {$0.1 >= geometryThreshold && close($0.0,center)} == true
                        let triangle=across.map {$0.1 >= geometryThreshold && close($0.0,right.0)} == true && backAcross.map {$0.1 >= geometryThreshold && close($0.0,left.0)} == true
                        let accepted=left.1 >= geometryThreshold && right.1 >= geometryThreshold && interiors && reciprocal && triangle
                        refined["geometryQualified"]=accepted
                        refined["rejection"]=accepted ? NSNull() : (!interiors ? "nativeRefinedSearchBoundary" : "nativeRefinedShapeReciprocalOrTriangle") as Any
                        if accepted {
                            let samples=[before[left.0],middle[center],after[right.0]]
                            refined["rgb"]=samples.map {s -> Any in
                                s.invalidMeterPixels == 0 && s.meter.count == 75 && s.meter.allSatisfy {$0.isFinite && $0 >= 0 && $0 < 0.95} ? s.meter as Any : NSNull()
                            }
                            func integratedLevel(_ sample:Samples) -> Double? {
                                guard sample.invalidMeterPixels == 0,sample.meter.count == 75,sample.meter.allSatisfy({$0.isFinite && $0 >= 0 && $0 < 0.95}) else {return nil}
                                let ys=(0..<25).map {i in 0.2126*sample.meter[i*3]+0.7152*sample.meter[i*3+1]+0.0722*sample.meter[i*3+2]}
                                guard ys.allSatisfy({$0 > 0.005}) else {return nil}
                                return log2(ys.reduce(0,+)/25)
                            }
                            let alpha=(times[event]!-times[event-1]!)/(times[event+1]!-times[event-1]!)
                            var perturbations=[Double](),invalidAlternative=false
                            if let middleLevel=integratedLevel(middle[center]),let leftLevel=integratedLevel(before[left.0]),let rightLevel=integratedLevel(after[right.0]) {
                                let nominal=middleLevel-(1-alpha)*leftLevel-alpha*rightLevel
                                for i in offsets.indices where close(i,left.0) && abs(offsets[i].0) < 3 && abs(offsets[i].1) < 3 {
                                    guard let leftScore=similarity(middle[center],before[i]),leftScore >= geometryThreshold else {continue}
                                    for j in offsets.indices where close(j,right.0) && abs(offsets[j].0) < 3 && abs(offsets[j].1) < 3 {
                                        guard let rightScore=similarity(middle[center],after[j]),rightScore >= geometryThreshold,
                                              let acrossScore=similarity(before[i],after[j]),acrossScore >= geometryThreshold else {continue}
                                        guard let av=integratedLevel(before[i]),let cv=integratedLevel(after[j]) else {invalidAlternative=true;continue}
                                        perturbations.append(middleLevel-(1-alpha)*av-alpha*cv)
                                    }
                                }
                                if !perturbations.isEmpty && !invalidAlternative {
                                    refined["integratedPulseStress"]=["nominalEV":nominal,"minimumEV":perturbations.min()!,"maximumEV":perturbations.max()!,"maximumChangeEV":perturbations.map {abs($0-nominal)}.max()!,"hypothesisCount":perturbations.count,"limitation":"Within-one-native-pixel local geometry perturbations passing all three shape comparisons. Not a calibrated sensor-noise or true-geometry confidence bound."]
                                }
                            }
                        }
                    }
                    refinedBrackets.append(refined)
                }
                let temporalAlpha=(times[event]!-times[event-1]!)/(times[event+1]!-times[event-1]!)
                var stress=pulseLocationSensitivity(stored[pi]![event-1]!,stored[pi]![event]!,stored[pi]![event+1]!,alpha:temporalAlpha,center:center)
                stress["event"]=event;temporalSensitivity.append(stress)
                let supported=checks.filter { ($0["frames"] as! [Int]) == [event-1,event] || ($0["frames"] as! [Int]) == [event,event+1] }
                let geometryQualified=supported.count == 2 && supported.allSatisfy({$0["reason"] as? String == "accepted"})
                // Keep failed central measurements inspectable, but never treat
                // photometric agreement as proof of geometric correspondence.
                if a.invalidMeterPixels+b.invalidMeterPixels+c.invalidMeterPixels > 0 {
                    pulses.append(["event":event,"geometryQualified":geometryQualified,"rejection":"nativeMeterClippingOrInvalid"]);continue
                }
                let alpha=(times[event]!-times[event-1]!)/(times[event+1]!-times[event-1]!)
                let evidence=CommonIlluminationComponent.pulseLinearLuminancePixels(before:a.meter,middle:b.meter,after:c.meter,alpha:alpha,reference:.arithmeticRadiance)
                let summaries=[a,b,c].map {sample -> [String:Any] in
                    let y=(0..<(sample.meter.count/3)).map {i in
                        0.2126*sample.meter[i*3]+0.7152*sample.meter[i*3+1]+0.0722*sample.meter[i*3+2]
                    }
                    return ["meanY":y.isEmpty ? 0 : y.reduce(0,+)/Double(y.count),
                            "minimumTileY":y.min() ?? 0,"maximumTileY":y.max() ?? 0]
                }
                pulses.append(["event":event,"geometryQualified":geometryQualified,"nativeTileSummaries":summaries,"rejection":evidence.rejection as Any? ?? NSNull(),"gain":evidence.gain as Any? ?? NSNull(),"offset":evidence.offset as Any? ?? NSNull(),"heldErrorEV":evidence.heldError,"representativeExcursionEV":evidence.representativeExcursion as Any? ?? NSNull()])
            }
            let sensitivity=available.map {frame -> [String:Any] in
                var row=meterSensitivity(stored[pi]![frame]!,center:center);row["frame"]=frame;return row
            }
            var probeReport:[String:Any]=["analysisX":probe.analysisX,"analysisY":probe.analysisY,"checks":checks,"pulses":pulses,"meterSensitivity":sensitivity,"temporalLocationSensitivity":temporalSensitivity]
            if refineMeters {probeReport["nativeRefinedBrackets"]=refinedBrackets}
            if exportMeters {
                probeReport["nativeMeterFrames"]=available.map {frame -> [String:Any] in
                    let sample=stored[pi]![frame]![center]
                    let valid=sample.invalidMeterPixels == 0 && sample.meter.count == 75 && sample.meter.allSatisfy {$0.isFinite && $0 >= 0 && $0 < 0.95}
                    return ["frame":frame,"pts":times[frame]!,"invalidContributors":sample.invalidMeterPixels,
                            "rgb":valid ? sample.meter as Any : NSNull()]
                }
            }
            reports.append(probeReport)
        }
        let report:[String:Any]=["source":diagnostic.source,"nonoverlappingSupportEnvelopes":retainedBounds,"overlappingProbesExcluded":overlapping,"boundaryProbesExcluded":boundary,"nativeSize":nativeSize,"nativeCornersValidatedBeforeInterpolation":true,"geometryRingPoints":ring.count,"meterTilePixels":25,"nativeMeterExport":exportMeters,"nativeRefinedMeterProbe":refineMeters,"seedPhase":[15,15],"seedSpacing":seedSpacing,"geometryThreshold":geometryThreshold,"edgeGeometryProbe":edgeGeometry,"luminanceGeometryProbe":luminanceGeometry,"boxGeometryProbe":boxGeometry,"nativeSupportExtent":supportExtent,"broadLandmarkProbe":broadGeometry,"geometryRingRadius":ringRadius,"geometryRingStride":ringStride,"geometryAverageHalf":geometryAverageHalf,"counts":counts,"rows":reports,"limitation":"Source-only native geometry ring and disjoint central radiance tiles. Pair masks exclude clipped geometry samples; central metering rejects any clipped/invalid pixel before averaging. No correction, geometry warp, independent temporal illumination truth, or encoded acceptance. Complete moving native support envelopes are disjoint between retained probes. This certifies pixel separation, not independent illumination or temporal donor truth."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out,options:.withoutOverwriting)
        print("NATIVE_SUPPORT",probes.count,counts,"affine",reports.flatMap {$0["pulses"] as! [[String:Any]]}.filter {$0["rejection"] is NSNull && $0["geometryQualified"] as? Bool == true}.count)
    }
}
