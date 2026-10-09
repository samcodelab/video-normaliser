import Foundation

/// Stabilise correction chroma only where the original RGB footprint is quiet.
/// This never estimates missing illumination or changes source image geometry.
enum QuietColourContinuity {
    static func quiet(_ a: SpatialThumbnail,_ b: SpatialThumbnail,x: Int,y: Int) -> Bool {
        guard a.width == b.width,a.height == b.height,a.rgb.count == a.width*a.height*3,b.rgb.count == a.rgb.count,
              x >= 2,y >= 2,x+2 < a.width,y+2 < a.height else { return false }
        for dy in -2...2 { for dx in -2...2 { for c in 0..<3 {
            let p = ((y+dy)*a.width+x+dx)*3+c,av = Double(a.rgb[p]),bv = Double(b.rgb[p])
            guard av.isFinite,bv.isFinite,av > 0.005,bv > 0.005,av < 0.95,bv < 0.95,
                  abs(log2(bv/av)) <= 0.01 else { return false }
        } } }
        return true
    }

    /// Keep node-guide luminance unchanged while changing its chromatic gain.
    /// Return nil at unobservable channels or clamps, not an invented target.
    static func preservingLuminance(old:[Double],shape:[Double],rgb:[Double],global:Double,limit:Double) -> [Double]? {
        guard old.count == 3,shape.count == 3,rgb.count == 3,limit.isFinite,limit > 0,global.isFinite,
              (old+shape+rgb).allSatisfy(\.isFinite),rgb.allSatisfy({$0 > 0.005 && $0 < 0.95}),
              old.allSatisfy({abs($0+global) < 1.9}) else {return nil}
        guard (0..<3).allSatisfy({rgb[$0]*exp2(old[$0]+global) < 0.94}) else {return nil}
        let centre = old.reduce(0,+)/3
        let desired = shape.map {$0+centre}
        let largest = zip(desired,old).map {abs($0-$1)}.max()!
        let fraction = min(1,limit/max(1e-12,largest))
        var proposed = zip(old,desired).map {$0+fraction*($1-$0)}
        let weights = [0.2126,0.7152,0.0722]
        let target = (0..<3).reduce(0.0) {$0+weights[$1]*rgb[$1]*exp2(old[$1])}
        let measured = (0..<3).reduce(0.0) {$0+weights[$1]*rgb[$1]*exp2(proposed[$1])}
        guard target > 0,measured > 0 else {return nil}
        let shift = log2(target/measured)
        proposed = proposed.map {$0+shift}
        guard proposed.allSatisfy({abs($0+global) < 1.9}),zip(proposed,old).allSatisfy({abs($0-$1) <= limit+1e-9}) else {return nil}
        guard (0..<3).allSatisfy({rgb[$0]*exp2(proposed[$0]+global) < 0.995}) else {return nil}
        return proposed
    }

    static func apply(samples:[ExposureSample],stops:[Double],fields:[SpatialField],options:SceneSettings) -> [SpatialField] {
        let amount = options.strength*options.spatialStrength*options.colourStrength
        guard options.reference == nil,[options.strength,options.spatialStrength,options.colourStrength].allSatisfy({$0.isFinite && (0...1).contains($0)}),
              options.radius.isFinite,options.radius >= 0.1,amount > 0,samples.count >= 3,samples.count == stops.count,fields.count == samples.count,
              samples.allSatisfy({$0.thumbnail != nil}),fields.allSatisfy({$0.surface != nil && $0.surface?.rowModel != true}) else {return fields}
        let images = samples.map {$0.thumbnail!},w = images[0].width,h = images[0].height
        guard w >= 5,h >= 5,images.allSatisfy({$0.width == w && $0.height == h && $0.rgb.count == w*h*3 && $0.rgb.allSatisfy(\.isFinite)}),
              fields.allSatisfy({$0.surface!.width == w && $0.surface!.height == h && $0.surface!.channelEV.count == w*h*3 && $0.surface!.guide.count == w*h*3}),
              stops.allSatisfy(\.isFinite) else {return fields}
        // Field nodes and source analysis pixel centres must coincide. Other
        // topologies abstain until their physical footprints are implemented.
        var gains = fields.map {$0.surface!.channelEV},changed = 0
        var certified:[(Int,Int)] = []
        typealias Evidence = CommonIlluminationComponent.ObservablePulseEvidence
        var donorCache:[Int:[(Int,Int,Evidence)]] = [:]
        var gates:[String:Int] = [:]
        func reject(_ reason:String) {gates[reason,default:0] += 1}
        func eventEvidence(_ i:Int,_ x:Int,_ y:Int) -> Evidence? {
            guard i > 0,i+1 < images.count,x >= 7,y >= 7,x+7 < w,y+7 < h else {return nil}
            let span = samples[i+1].time-samples[i-1].time
            guard span.isFinite,span > 0,span <= 2*options.radius+1e-9 else {return nil}
            let alpha = (samples[i].time-samples[i-1].time)/span
            func pixels(_ image:SpatialThumbnail) -> [Double] {
                var values:[Double] = []
                for dy in -2...2 {for dx in -2...2 {for c in 0..<3 {values.append(Double(image.rgb[((y+dy)*w+x+dx)*3+c]))}}}
                return values
            }
            let evidence = CommonIlluminationComponent.pulsePixels(before:pixels(images[i-1]),middle:pixels(images[i]),after:pixels(images[i+1]),alpha:alpha,tolerance:0.04)
            guard evidence.rejection == nil,evidence.channelExcursion.count == 3 else {reject(evidence.rejection ?? "invalidChannels");return nil}
            let mean = evidence.channelExcursion.reduce(0,+)/3
            guard sqrt(evidence.channelExcursion.reduce(0.0) {$0+pow($1-mean,2)}/3) > 0.04 else {reject("noChromaticEvent");return nil}
            guard SurfaceTracking.stationaryContrastConfidence(images[i-1],images[i],x:x,y:y) > 0.5 else {reject("stationaryGeometry");return nil}
            return .init(channelExcursion:evidence.channelExcursion.map {Optional($0)},minimumMeasuredLuminanceCoverage:1,representativeExcursion:mean,heldError:evidence.heldError,rejection:nil)
        }
        func supportedEvent(_ i:Int,_ x:Int,_ y:Int) -> Bool {
            guard let query = eventEvidence(i,x,y) else {return false}
            if donorCache[i] == nil {
                var donors:[(Int,Int,Evidence)] = []
                // These central photometry footprints are disjoint. Donors
                // close to the query are separately excluded below.
                for yy in stride(from:7,to:h-7,by:8) {for xx in stride(from:7,to:w-7,by:8) {
                    if let evidence = eventEvidence(i,xx,yy) {donors.append((xx,yy,evidence))}
                }}
                donorCache[i] = donors
            }
            let independent = donorCache[i]!.filter {abs($0.0-x) > 8 || abs($0.1-y) > 8}
            guard independent.count >= 4 else {reject("insufficientIndependentDonors");return false}
            let agrees = CommonIlluminationComponent.pulseColourCorroborates(query:query,donors:independent.map {$0.2},minimumDonors:4,tolerance:0.04)
            if !agrees {reject("donorRGBDisagreement")}
            return agrees
        }
        for y in 2..<(h-2) {for x in 2..<(w-2) {
            if Task.isCancelled {return fields}
            let p = y*w+x
            var start = 0
            func finish(_ end:Int) {
                guard end-start >= 3,supportedEvent(start,x,y) else {return}
                let shapes = (start..<end).map {i -> [Double] in
                    let old = (0..<3).map {Double(fields[i].surface!.channelEV[p*3+$0])}
                    let output = (0..<3).map {log2(Double(images[i].rgb[p*3+$0]))+old[$0]}
                    let mean = output.reduce(0,+)/3
                    return output.map {$0-mean}
                }
                var target = (0..<3).map {c in ExposureMath.median(shapes.map {$0[c]})}
                let mean = target.reduce(0,+)/3;target = target.map {$0-mean}
                let desired = (start..<end).map {i -> [Double] in
                    let source = (0..<3).map {log2(Double(images[i].rgb[p*3+$0]))}
                    let mean = source.reduce(0,+)/3
                    return (0..<3).map {target[$0]-(source[$0]-mean)}
                }
                var largest = 0.0
                for i in start..<end {
                    let old = (0..<3).map {Double(fields[i].surface!.channelEV[p*3+$0])},mean = old.reduce(0,+)/3
                    largest = max(largest,(0..<3).map {abs(desired[i-start][$0]-(old[$0]-mean))}.max()!)
                }
                // One common interpolation amount preserves every quiet edge's
                // chromatic contraction. Independent per-frame clipping does not.
                let fraction = min(1,0.025*amount/max(1e-12,largest))
                var proposals:[[Double]] = []
                for i in start..<end {
                    let map = fields[i].surface!,old = (0..<3).map {Double(map.channelEV[p*3+$0])}
                    let rgb = (0..<3).map {Double(images[i].rgb[p*3+$0])},mean = old.reduce(0,+)/3
                    let shape = (0..<3).map {(old[$0]-mean)+fraction*(desired[i-start][$0]-(old[$0]-mean))}
                    guard let proposed = preservingLuminance(old:old,shape:shape,rgb:rgb,global:stops[i]+(fields[i].brightnessEV ?? 0),limit:0.05*amount) else {return}
                    proposals.append(proposed)
                }
                for i in start..<end {
                    let old = (0..<3).map {Double(fields[i].surface!.channelEV[p*3+$0])},proposed = proposals[i-start]
                    for c in 0..<3 {gains[i][p*3+c] = Float(proposed[c])}
                    if zip(proposed,old).contains(where:{abs($0-$1) > 1e-6}) {changed += 1}
                    if i > start {certified.append((i,p))}
                }
            }
            for i in 1..<images.count {
                if samples[i].time-samples[start].time > 2*options.radius+1e-9 || !quiet(images[i-1],images[i],x:x,y:y) || !quiet(images[start],images[i],x:x,y:y) {finish(i);start = i}
            }
            finish(images.count)
        }}
        if ProcessInfo.processInfo.environment["FRANKLUMA_QUIET_COLOUR_DIAGNOSTICS"] == "1" {
            print("QUIET_COLOUR_GATES",gates.sorted {$0.key < $1.key}.map {"\($0.key)=\($0.value)"}.joined(separator:" "),"changedNodes",changed)
        }
        guard changed > 0,!certified.isEmpty else {return fields}
        var result = fields
        for i in result.indices {
            let map = fields[i].surface!
            result[i].surface = .init(width:w,height:h,channelEV:gains[i],guide:map.guide,rowModel:map.rowModel)
        }
        func rendered(_ i:Int,_ p:Int,_ candidate:[SpatialField]) -> [Double] {
            SpatialRenderer.surfaceRGB((0..<3).map {Double(images[i].rgb[p*3+$0])},x:(Double(p%w)+0.5)/Double(w),y:(Double(p/w)+0.5)/Double(h),map:candidate[i].surface!,global:stops[i]+(candidate[i].brightnessEV ?? 0))
        }
        func chroma(_ rgb:[Double]) -> [Double] {
            let logs = rgb.map {log2(max(1e-9,$0))},mean = logs.reduce(0,+)/3
            return logs.map {$0-mean}
        }
        func light(_ rgb:[Double]) -> Double {log2(max(1e-9,0.2126*rgb[0]+0.7152*rgb[1]+0.0722*rgb[2]))}
        var before = 0.0,after = 0.0
        for (i,p) in certified {
            let a = chroma(rendered(i-1,p,fields)),b = chroma(rendered(i,p,fields))
            let c = chroma(rendered(i-1,p,result)),d = chroma(rendered(i,p,result))
            let old = zip(a,b).reduce(0.0) {$0+pow($1.1-$1.0,2)},new = zip(c,d).reduce(0.0) {$0+pow($1.1-$1.0,2)}
            guard new <= old+pow(0.002*amount,2) else {
                print("QUIET_COLOUR_REJECTED","reason","quietEdgeRegression","frame",i,"node",p,"before",old,"after",new)
                return fields
            }
            before += old;after += new
        }
        // Check every affected analysis pixel, including unsupported edges of
        // the field interpolation, through the actual guidance/highlight model.
        for i in images.indices {for p in 0..<(w*h) {
            if Task.isCancelled {return fields}
            let a = rendered(i,p,fields),b = rendered(i,p,result)
            guard abs(light(b)-light(a)) <= 0.003*amount+1e-9 else {
                print("QUIET_COLOUR_REJECTED","reason","brightnessChange","frame",i,"node",p,"difference",light(b)-light(a))
                return fields
            }
        }}
        guard before > 1e-10,after < before*0.9 else {return fields}
        // Keep timeline diagnostics aligned with the accepted field.
        for i in result.indices {for p in result[i].applied.indices {
            let x = min(w-1,Int((Double(p%24)+0.5)/24*Double(w))),y = min(h-1,Int((Double(p/24)+0.5)/14*Double(h))),k = (y*w+x)*3
            result[i].applied[p] = 0.2126*Double(gains[i][k])+0.7152*Double(gains[i][k+1])+0.0722*Double(gains[i][k+2])
            result[i].requested[p] = result[i].applied[p]
        }}
        print("QUIET_COLOUR_CONTINUITY", "changedNodes",changed,"sourceQuietEdges",certified.count,"beforeEnergy",before,"afterEnergy",after)
        return result
    }
}
