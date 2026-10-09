import CoreImage
import Foundation

enum SpatialRenderer {
    private static let surfaceKernel = CIKernel(source: """
        float guidanceWeight(vec3 source, vec3 guide) {
            vec3 difference = log2(max(source,vec3(0.003))/max(guide,vec3(0.003)));
            return exp(-dot(difference,difference)/0.3);
        }
        kernel vec4 surfaceExposure(sampler sourceImage, sampler gains, sampler guide, sampler tone, vec4 bounds, vec2 dimensions, float globalEV, float manualEV, float showField) {
            vec4 source = sample(sourceImage,samplerTransform(sourceImage,destCoord()));
            vec2 position = clamp((destCoord()-bounds.xy)/bounds.zw*dimensions-vec2(0.5),vec2(0.0),dimensions-vec2(1.0));
            vec2 base = min(floor(position),dimensions-vec2(2.0));
            vec2 f = position-base;
            vec2 p00 = base+vec2(0.5), p10 = p00+vec2(1.0,0.0), p01 = p00+vec2(0.0,1.0), p11 = p00+vec2(1.0);
            vec4 weights = vec4((1.0-f.x)*(1.0-f.y),f.x*(1.0-f.y),(1.0-f.x)*f.y,f.x*f.y);
            vec4 support = vec4(guidanceWeight(source.rgb,sample(guide,samplerTransform(guide,p00)).rgb),
                guidanceWeight(source.rgb,sample(guide,samplerTransform(guide,p10)).rgb),
                guidanceWeight(source.rgb,sample(guide,samplerTransform(guide,p01)).rgb),
                guidanceWeight(source.rgb,sample(guide,samplerTransform(guide,p11)).rgb));
            vec4 guided = weights*max(support,vec4(0.0001));
            guided /= dot(guided,vec4(1.0));
            vec3 ev = sample(gains,samplerTransform(gains,p00)).rgb*guided.x
                +sample(gains,samplerTransform(gains,p10)).rgb*guided.y
                +sample(gains,samplerTransform(gains,p01)).rgb*guided.z
                +sample(gains,samplerTransform(gains,p11)).rgb*guided.w;
            float toneSlope = sample(tone,samplerTransform(tone,p00)).r*guided.x
                +sample(tone,samplerTransform(tone,p10)).r*guided.y
                +sample(tone,samplerTransform(tone,p01)).r*guided.z
                +sample(tone,samplerTransform(tone,p11)).r*guided.w;
            float sourceLight = dot(source.rgb,vec3(0.2126,0.7152,0.0722));
            float toneFeature = clamp(log2(max(0.005,sourceLight)/0.18),-3.0,2.0);
            vec3 baseEV = clamp(ev + vec3(globalEV),vec3(-2.0),vec3(2.0));
            float sharedTone = clamp(clamp(toneSlope,-0.5,0.5)*toneFeature,
                -2.0-min(baseEV.r,min(baseEV.g,baseEV.b)),2.0-max(baseEV.r,max(baseEV.g,baseEV.b)));
            vec3 gain = exp2(baseEV+vec3(sharedTone+manualEV));
            vec3 corrected = source.rgb * gain;
            float peak = max(corrected.r,max(corrected.g,corrected.b));
            float originalPeak = max(source.r,max(source.g,source.b));
            if (peak > 0.995 && peak > originalPeak) corrected *= max(0.995,originalPeak)/peak;
            if (showField > 0.5) {
                float before = dot(source.rgb,vec3(0.2126,0.7152,0.0722));
                float after = dot(corrected,vec3(0.2126,0.7152,0.0722));
                float applied = dot(clamp(ev+vec3(globalEV),vec3(-2.0),vec3(2.0))+vec3(manualEV),vec3(0.2126,0.7152,0.0722));
                if (before > 0.00001) applied = log2(max(0.000001,after/before));
                float value = clamp(applied,-1.0,1.0);
                return vec4(max(0.0,value),1.0-abs(value),max(0.0,-value),1.0);
            }
            return vec4(corrected,source.a);
        }
        """)!
    // CI works in linear light. The fitted affine luminance map changes
    // contrast only where neutral midtones support it. Shadows and saturated
    // subjects use the exposure-only field. One common gain multiplies RGB,
    // preserving linear chromaticity; no neighbouring image pixels are blended.
    private static let kernel = CIColorKernel(source: """
        kernel vec4 spatialExposure(__sample source, __sample field, __sample validation, float globalEV, float showField, float manualEV, float brightnessEV, float preserveBrightness) {
            float gain = exp2(clamp(globalEV + field.r, -2.0, 2.0));
            float peak = max(source.r, max(source.g, source.b));
            float light = dot(source.rgb, vec3(0.2126, 0.7152, 0.0722));
            float low = min(source.r, min(source.g, source.b));
            float chroma = (peak-low) / max(0.001,peak);
            float toneSupport = smoothstep(0.03, 0.12, light) * (1.0-smoothstep(0.15,0.45,chroma));
            float toneGain = max(0.0, gain + field.g / max(0.001,light));
            float exposureGain = exp2(clamp(globalEV + field.b, -2.0, 2.0));
            gain = mix(exposureGain, toneGain, toneSupport);
            if (preserveBrightness > 0.5) {
                gain = clamp(gain, exposureGain * exp2(-0.5), exposureGain * exp2(0.5));
                gain = exp2(clamp(log2(max(0.000001,gain)) + brightnessEV + validation.r, -2.0, 2.0));
            }
            gain *= exp2(manualEV);
            if (gain > 1.0 && peak > 0.0) {
                gain = min(gain, max(1.0, 0.995 / peak));
            }
            if (showField > 0.5) {
                float ev = clamp(log2(max(0.0001,gain)), -1.0, 1.0);
                return vec4(max(0.0,ev), 1.0-abs(ev), max(0.0,-ev), 1.0);
            }
            return vec4(source.rgb * gain, source.a);
        }
        """)!

    static func render(_ source: CIImage, global: Double, field: SpatialField?, diagnostic: PreviewMode = .corrected, manualEV: Double = 0) -> CIImage {
        // Preserve the unedited passthrough path; manual edits use the same
        // highlight protection whether or not an automatic field exists.
        if field == nil, manualEV == 0 {
            return source.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: global])
        }
        let field = field ?? SpatialField()
        if let surface = field.surface, diagnostic != .confidence && diagnostic != .motion {
            let rgba = (0..<(surface.width*surface.height)).flatMap { p in
                [surface.channelEV[p*3],surface.channelEV[p*3+1],surface.channelEV[p*3+2],Float(1)]
            }
            let guide = (0..<(surface.width*surface.height)).flatMap { p in
                [surface.guide[p*3],surface.guide[p*3+1],surface.guide[p*3+2],Float(1)]
            }
            let image = bitmap(rgba, columns: surface.width, rows: surface.height)
            let guidance = bitmap(guide, columns: surface.width, rows: surface.height)
            let suppliedTone = surface.toneEV
            let toneValues = suppliedTone?.count == surface.width*surface.height ? suppliedTone!.map {$0.isFinite ? $0 : 0} : Array(repeating:Float(0),count:surface.width*surface.height)
            let tone = bitmap(toneValues.flatMap {[$0,Float(0),Float(0),Float(1)]},columns:surface.width,rows:surface.height)
            let bounds = CIVector(x: source.extent.minX,y: source.extent.minY,z: source.extent.width,w: source.extent.height)
            let dimensions = CIVector(x: CGFloat(surface.width),y: CGFloat(surface.height))
            return surfaceKernel.apply(extent: source.extent, roiCallback: { index, rect in
                index == 0 ? rect : CGRect(x: 0,y: 0,width: surface.width,height: surface.height)
            }, arguments: [source,image,guidance,tone,bounds,dimensions,global+(field.brightnessEV ?? 0),manualEV,diagnostic == .field ? 1.0 : 0.0]) ?? source
        }
        if diagnostic == .confidence || diagnostic == .motion {
            let values = diagnostic == .motion ? field.motion : field.confidence
            let rgba = values.flatMap { [Float($0), Float($0), Float($0), Float(1)] }
            return map(rgba, columns: field.sampleColumns, rows: field.sampleRows, extent: source.extent)
        }
        let rgba = field.stops.indices.flatMap { [Float(field.stops[$0]), Float(field.offsets[$0]), Float(field.exposureStops[$0]), Float(1)] }
        let image = map(rgba, columns: field.columns, rows: field.rows, extent: source.extent)
        let validationValues = (field.validationStops ?? Array(repeating: 0, count: field.columns * field.rows)).flatMap { [Float($0), Float(0), Float(0), Float(1)] }
        let validation = map(validationValues, columns: field.columns, rows: field.rows, extent: source.extent)
        return kernel.apply(extent: source.extent, arguments: [source, image, validation, global, diagnostic == .field ? 1.0 : 0.0, manualEV, field.brightnessEV ?? 0, field.brightnessEV == nil ? 0.0 : 1.0]) ?? source
    }

    private static func bitmap(_ values: [Float], columns: Int, rows: Int) -> CIImage {
        let data = values.withUnsafeBytes { Data($0) }
        return CIImage(bitmapData: data, bytesPerRow: columns*16, size: CGSize(width: columns,height: rows), format: .RGBAf,colorSpace: nil).clampedToExtent()
    }

    private static func map(_ values: [Float], columns: Int, rows: Int, extent: CGRect) -> CIImage {
        let data = values.withUnsafeBytes { Data($0) }
        // Node centres span the image edges; clamp before scaling to avoid
        // transparent borders. Bilinear interpolation gives a continuous field.
        let image = CIImage(bitmapData: data, bytesPerRow: columns * 16, size: CGSize(width: columns, height: rows), format: .RGBAf, colorSpace: nil)
        let sx = extent.width / Double(columns-1), sy = extent.height / Double(rows-1)
        return image.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -0.5, y: -0.5))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)
    }
}

// Predict the renderer on the existing linear-light analysis thumbnail. This
// includes tone support, the scene safeguard and clipping, rather than assuming
// that the sum of two EV estimates describes the pixels that will be exported.
extension SpatialRenderer {
    /// Measure gain on transported source samples by interpolating rendered
    /// radiance, never EVs or RGB before the nonlinear guidance/highlight response.
    static func sampledSurfaceGain(image: SpatialThumbnail,map: SurfaceLighting.Map,global: Double,
                                   points: [(x:Double,y:Double)],validPixels: [Int],sampleWeights: [Double]? = nil) -> Double? {
        guard global.isFinite,image.width >= 2,image.height >= 2,
              image.rgb.count == image.width*image.height*3,map.width >= 2,map.height >= 2,
              map.guide.count == map.width*map.height*3,map.channelEV.count == map.guide.count,
              !validPixels.isEmpty,Set(validPixels).count == validPixels.count,
              validPixels.allSatisfy({ points.indices.contains($0) }),
              map.guide.allSatisfy(\.isFinite),map.channelEV.allSatisfy(\.isFinite) else { return nil }
        guard sampleWeights == nil || (sampleWeights!.count == points.count && sampleWeights!.allSatisfy { $0.isFinite && $0 > 0 }) else { return nil }
        let weights = [0.2126,0.7152,0.0722]
        var before = 0.0,after = 0.0
        for index in validPixels {
            let point = points[index]
            guard point.x.isFinite,point.y.isFinite,point.x >= 0,point.y >= 0,
                  point.x < Double(image.width-1),point.y < Double(image.height-1) else { return nil }
            let ix = Int(floor(point.x)),iy = Int(floor(point.y)),fx = point.x-Double(ix),fy = point.y-Double(iy)
            for (dx,dy,weight) in [(0,0,(1-fx)*(1-fy)),(1,0,fx*(1-fy)),(0,1,(1-fx)*fy),(1,1,fx*fy)] where weight > 0 {
                let x = ix+dx,y = iy+dy,p = (y*image.width+x)*3
                let rgb = (0..<3).map { Double(image.rgb[p+$0]) }
                guard rgb.allSatisfy(\.isFinite) else { return nil }
                let rendered = surfaceRGB(rgb,x:(Double(x)+0.5)/Double(image.width),y:(Double(y)+0.5)/Double(image.height),map:map,global:global)
                before += (sampleWeights?[index] ?? 1)*weight*zip(rgb,weights).reduce(0) { $0+$1.0*$1.1 }
                after += (sampleWeights?[index] ?? 1)*weight*zip(rendered,weights).reduce(0) { $0+$1.0*$1.1 }
            }
        }
        guard before.isFinite,after.isFinite,before > 1e-9,after > 1e-9 else { return nil }
        let result = log2(after/before)
        return result.isFinite ? result : nil
    }

    /// Project a linearized measurement toward its allowed interval while
    /// retaining each variable's original correction budget. Saturation can
    /// leave residual violation; the caller must remeasure and verify it.
    static func boundedMeasurementProjection(values: [Double],gradient: [Double],
        bounds: [(lower:Double,upper:Double)],measurement: Double,allowed: ClosedRange<Double>) -> [Double]? {
        guard !values.isEmpty,gradient.count == values.count,bounds.count == values.count,
              measurement.isFinite,allowed.lowerBound.isFinite,allowed.upperBound.isFinite,
              values.allSatisfy(\.isFinite),gradient.allSatisfy(\.isFinite),
              bounds.enumerated().allSatisfy({ i,b in b.lower.isFinite && b.upper.isFinite && b.lower <= b.upper && values[i] >= b.lower-1e-7 && values[i] <= b.upper+1e-7 }) else { return nil }
        let target = max(allowed.lowerBound,min(allowed.upperBound,measurement))
        if target == measurement { return values }
        let norm = gradient.reduce(0) { $0+$1*$1 }
        guard norm.isFinite,norm > 1e-16 else { return nil }
        let step = (target-measurement)/norm
        return values.indices.map { i in max(bounds[i].lower,min(bounds[i].upper,values[i]+step*gradient[i])) }
    }

    /// Neutral EV derivative on the observed footprint; geometry and guides stay fixed.
    static func surfaceGainJacobian(image: SpatialThumbnail,map: SurfaceLighting.Map,global: Double,
                                    point: (x:Int,y:Int),footprint: [(x:Double,y:Double)]? = nil,
                                    validPixels: [Int]? = nil,sampleWeights: [Double]? = nil,toneDerivative: Bool = false) -> [(Int,Double)]? {
        guard image.rgb.count == image.width*image.height*3,map.width >= 2,map.height >= 2,
              map.guide.count == map.width*map.height*3,map.channelEV.count == map.guide.count,
              global.isFinite,map.guide.allSatisfy(\.isFinite),map.channelEV.allSatisfy(\.isFinite) else { return nil }
        // A smaller step avoids mixing the two sides of a highlight kink
        // when a finite kernel gives its taps different response weights.
        let epsilon = sampleWeights?.contains(where: { $0 != 1 }) == true ? 0.00001 : 0.001
        let luminance = [0.2126,0.7152,0.0722]
            guard point.x >= 2,point.y >= 2,
                  point.x+2 < image.width,point.y+2 < image.height else { return nil }
            var coefficients = [Int:Double](),totalLight = 0.0,valid = true
            let samples = footprint ?? (-2...2).flatMap { dy in (-2...2).map { dx in (x:Double(point.x+dx),y:Double(point.y+dy)) } }
            let selected = validPixels ?? Array(samples.indices)
            guard sampleWeights == nil || (sampleWeights!.count == samples.count && sampleWeights!.allSatisfy { $0.isFinite && $0 > 0 }) else { return nil }
            guard !selected.isEmpty,Set(selected).count == selected.count,selected.allSatisfy({ samples.indices.contains($0) }) else { return nil }
            for sampleIndex in selected {
                let sample = samples[sampleIndex]
                guard sample.x.isFinite,sample.y.isFinite,sample.x >= 0,sample.y >= 0,
                      sample.x <= Double(image.width-1),sample.y <= Double(image.height-1) else { valid = false;continue }
                let ix = Int(floor(sample.x)),iy = Int(floor(sample.y)),fx = sample.x-Double(ix),fy = sample.y-Double(iy)
                for (dx,dy,samplingWeight) in [(0,0,(1-fx)*(1-fy)),(1,0,fx*(1-fy)),(0,1,(1-fx)*fy),(1,1,fx*fy)] where samplingWeight > 0 {
                let px = ix+dx,py = iy+dy,p = (py*image.width+px)*3
                let rgb = (0..<3).map { Double(image.rgb[p+$0]) }
                guard rgb.allSatisfy({ $0.isFinite && (footprint != nil || $0 >= 0) }) else { valid = false;continue }
                let x = (Double(px)+0.5)/Double(image.width),y = (Double(py)+0.5)/Double(image.height)
                func light(_ exposure: Double) -> Double {
                    let out = surfaceRGB(rgb,x:x,y:y,map:map,global:exposure)
                    return zip(out,luminance).reduce(0) { $0+$1.0*$1.1 }
                }
                let original = light(global)
                let feature = toneDerivative ? max(-3,min(2,log2(max(0.005,zip(rgb,luminance).reduce(0.0) {$0+$1.0*$1.1})/0.18))) : 1
                let response = (light(global+epsilon)-light(global-epsilon))/(2*epsilon*log(2.0))*feature
                totalLight += (sampleWeights?[sampleIndex] ?? 1)*samplingWeight*original
                let weighted = surfaceBasis(x:x,y:y,width:map.width,height:map.height).map { node,weight -> (Int,Double) in
                    let difference = (0..<3).reduce(0.0) { $0+pow(log2(max(0.003,rgb[$1])/max(0.003,Double(map.guide[node*3+$1]))),2) }
                    return (node,weight*max(0.0001,exp(-difference/0.3)))
                }
                let total = weighted.reduce(0) { $0+$1.1 }
                for (node,weight) in weighted { coefficients[node,default:0] += (sampleWeights?[sampleIndex] ?? 1)*samplingWeight*response*weight/total }
            } }
            guard valid,totalLight.isFinite,totalLight > 1e-9 else { return nil }
            let terms = coefficients.keys.sorted().map { ($0,coefficients[$0]!/totalLight) }
            let response = terms.reduce(0) { $0+$1.1 }
            // A nearly clipped patch cannot reliably authorize a gain fit.
            guard response.isFinite,(toneDerivative ? abs(response) > 0.05 && abs(response) <= 3.03 : response > 0.2 && response <= 1.01),
                  terms.allSatisfy({ $0.1.isFinite }) else { return nil }
        return terms
    }

    /// Fit neutral map increments to desired patch gains through the same
    /// RGB guidance and highlight/clamp response as the renderer. Unobserved
    /// nodes receive no increment unless explicit spatial regularization is requested.
    /// Source pixels and map guidance stay fixed.
    static func fitSurfaceIncrements(image: SpatialThumbnail,map: SurfaceLighting.Map,global: Double,
                                     observations: [(x:Int,y:Int,delta:Double)],regularization: Double = 0.001,
                                     spatialRegularization: Double = 0,
                                     observationWeights: [Double]? = nil,
                                     bounds: [(lower:Double,upper:Double)]? = nil,
                                     footprints: [[(x:Double,y:Double)]]? = nil,validPixels: [[Int]]? = nil,footprintWeights: [[Double]]? = nil) -> [Float]? {
        guard observations.count >= 12,image.width >= 5,image.height >= 5,
              image.rgb.count == image.width*image.height*3,map.width >= 2,map.height >= 2,
              map.guide.count == map.width*map.height*3,map.channelEV.count == map.guide.count,
              global.isFinite,regularization.isFinite,regularization > 0,
              spatialRegularization.isFinite,spatialRegularization >= 0,
              map.guide.allSatisfy(\.isFinite) else { return nil }
        guard bounds == nil || (bounds!.count == map.width*map.height && bounds!.allSatisfy {
            $0.lower.isFinite && $0.upper.isFinite && $0.lower <= $0.upper
        }) else { return nil }
        guard (footprints == nil && validPixels == nil) ||
              (footprints?.count == observations.count && validPixels?.count == observations.count) else { return nil }
        guard observationWeights == nil || (observationWeights!.count == observations.count && observationWeights!.allSatisfy { $0.isFinite && $0 > 0 }) else { return nil }
        guard footprintWeights == nil || (footprints != nil && footprintWeights!.count == observations.count && zip(footprintWeights!,footprints!).allSatisfy { $0.count == $1.count && $0.allSatisfy { $0.isFinite && $0 > 0 } }) else { return nil }
        var rows = [([(Int,Double)],Double)]()
        for (index,point) in observations.enumerated() {
            guard point.delta.isFinite,let terms = surfaceGainJacobian(image:image,map:map,global:global,
                point:(point.x,point.y),footprint:footprints?[index],validPixels:validPixels?[index],sampleWeights:footprintWeights?[index]) else { continue }
            let weight = sqrt(observationWeights?[index] ?? 1)
            rows.append((terms.map { ($0.0,$0.1*weight) },point.delta*weight))
        }
        guard rows.count >= 12 else { return nil }
        let nodes = spatialRegularization > 0 ? Array(0..<map.width*map.height) : Array(Set(rows.flatMap { $0.0.map { $0.0 } })).sorted()
        let columns = Dictionary(uniqueKeysWithValues:nodes.enumerated().map { ($0.element,$0.offset) })
        var equations = rows.map { ($0.0.map { (columns[$0.0]!,$0.1) },$0.1) }
        if spatialRegularization > 0 {
            // A source-guided graph prior propagates sparse gains while reducing
            // coupling across reflectance boundaries. It does not add evidence.
            for y in 0..<map.height { for x in 0..<map.width {
                let a = y*map.width+x
                for b in [x+1 < map.width ? a+1 : -1,y+1 < map.height ? a+map.width : -1] where b >= 0 {
                    let distance = (0..<3).reduce(0.0) { total,c in
                        let contrast = log2(max(0.003,Double(map.guide[a*3+c]))/max(0.003,Double(map.guide[b*3+c])))
                        return total+contrast*contrast
                    }
                    let coefficient = sqrt(spatialRegularization*exp(-distance/0.3))
                    if coefficient > 1e-8 { equations.append(([(columns[a]!,coefficient),(columns[b]!,-coefficient)],0)) }
                }
            } }
        }
        func dot(_ a: [Double],_ b: [Double]) -> Double { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }
        func product(_ v: [Double]) -> [Double] {
            var out = v.map { regularization*$0 }
            for (terms,_) in equations {
                let value = terms.reduce(0) { $0+v[$1.0]*$1.1 }
                for (column,coefficient) in terms { out[column] += coefficient*value }
            }
            return out
        }
        var rhs = [Double](repeating:0,count:nodes.count)
        for (terms,target) in equations { for (column,coefficient) in terms { rhs[column] += coefficient*target } }
        var solution = rhs.map { _ in 0.0 },residual = rhs,direction = rhs,energy = dot(rhs,rhs)
        let threshold = max(1e-24,energy*1e-20)
        for _ in 0..<min(4096,max(32,nodes.count*4)) {
            if energy <= threshold { break }
            let applied = product(direction),denominator = dot(direction,applied)
            guard denominator.isFinite,denominator > 0 else { return nil }
            let step = energy/denominator
            solution = zip(solution,direction).map { $0.0+step*$0.1 }
            residual = zip(residual,applied).map { $0.0-step*$0.1 }
            let next = dot(residual,residual),beta = next/energy
            direction = zip(residual,direction).map { $0.0+beta*$0.1 };energy = next
        }
        guard energy <= max(threshold,dot(rhs,rhs)*1e-12),solution.allSatisfy(\.isFinite) else { return nil }
        if let bounds {
            let limits = nodes.map { bounds[$0] }
            func project(_ value: Double,_ column: Int) -> Double {
                max(limits[column].lower,min(limits[column].upper,value))
            }
            solution = solution.enumerated().map { project($0.element,$0.offset) }
            var associations = [[(row:Int,coefficient:Double)]](repeating:[],count:nodes.count)
            var diagonal = [Double](repeating:regularization,count:nodes.count)
            for (j,equation) in equations.enumerated() { for (column,coefficient) in equation.0 {
                associations[column].append((j,coefficient));diagonal[column] += coefficient*coefficient
            } }
            var errors = equations.map { terms,target in terms.reduce(0) { $0+solution[$1.0]*$1.1 }-target }
            // Box-constrained coordinate minimization redistributes the fit
            // around saturated nodes instead of scaling every region together.
            for _ in 0..<4096 {
                if Task.isCancelled { return nil }
                var largestChange = 0.0
                for column in nodes.indices {
                    let gradient = associations[column].reduce(regularization*solution[column]) { $0+$1.coefficient*errors[$1.row] }
                    let updated = project(solution[column]-gradient/diagonal[column],column)
                    let change = updated-solution[column]
                    solution[column] = updated;largestChange = max(largestChange,abs(change))
                    for entry in associations[column] { errors[entry.row] += entry.coefficient*change }
                }
                if largestChange < 1e-9 { break }
            }
            let maximumProjectedGradient = nodes.indices.map { column -> Double in
                let gradient = associations[column].reduce(regularization*solution[column]) { $0+$1.coefficient*errors[$1.row] }
                return abs(solution[column]-project(solution[column]-gradient/diagonal[column],column))
            }.max() ?? 0
            guard maximumProjectedGradient < 1e-7 else {
                print("COMMON_LIGHT_SPATIAL_FIT_REJECTED", "reason","boundedConvergence","projectedGradient",maximumProjectedGradient)
                return nil
            }
        }
        var increments = [Float](repeating:0,count:map.width*map.height)
        for (column,node) in nodes.enumerated() { increments[node] = Float(solution[column]) }
        guard increments.allSatisfy(\.isFinite) else { return nil }
        return increments
    }
    /// Gain samples represent analysis-pixel centres, not the image edges.
    /// Match the native kernel's half-pixel convention at every resolution.
    static func surfaceBasis(x: Double,y: Double,width: Int,height: Int) -> [(Int,Double)] {
        let xx = max(0,min(Double(width-1),x*Double(width)-0.5))
        let yy = max(0,min(Double(height-1),y*Double(height)-0.5))
        let ix = min(width-2,Int(xx)),iy = min(height-2,Int(yy))
        let fx = xx-Double(ix),fy = yy-Double(iy)
        return [(iy*width+ix,(1-fx)*(1-fy)),(iy*width+ix+1,fx*(1-fy)),
                ((iy+1)*width+ix,(1-fx)*fy),((iy+1)*width+ix+1,fx*fy)]
    }

    static func surfaceRGB(_ rgb: [Double],x: Double,y: Double,map: SurfaceLighting.Map,global: Double) -> [Double] {
        let weighted = surfaceBasis(x: x,y: y,width: map.width,height: map.height).map { node,weight -> (Int,Double) in
            let difference = (0..<3).reduce(0.0) { $0+pow(log2(max(0.003,rgb[$1])/max(0.003,Double(map.guide[node*3+$1]))),2) }
            return (node,weight*max(0.0001,exp(-difference/0.3)))
        }
        let total = weighted.reduce(0) { $0+$1.1 }
        let light = 0.2126*rgb[0]+0.7152*rgb[1]+0.0722*rgb[2]
        let toneFeature = max(-3,min(2,log2(max(0.005,light)/0.18)))
        let hasTone = map.toneEV?.count == map.width*map.height
        let proposedTone = max(-0.5,min(0.5,weighted.reduce(0.0) {$0+Double(hasTone && map.toneEV![$1.0].isFinite ? map.toneEV![$1.0] : 0)*$1.1/total}))*toneFeature
        let baseEV = (0..<3).map {c in max(-2,min(2,global+weighted.reduce(0) {$0+Double(map.channelEV[$1.0*3+c])*$1.1/total}))}
        let tone = max(-2-baseEV.min()!,min(2-baseEV.max()!,proposedTone))
        var corrected = (0..<3).map {c in rgb[c]*pow(2,baseEV[c]+tone)}
        let peak = corrected.max()!,originalPeak = rgb.max()!
        if peak > 0.995,peak > originalPeak { corrected = corrected.map { $0*max(0.995,originalPeak)/peak } }
        return corrected
    }

    static func predictedCells(_ thumbnail: SpatialThumbnail, global: Double, field: SpatialField,
                               region: CGRect? = nil) -> [Double] {
        let bounds = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        var sums = [Double](repeating: 0, count: 336), counts = [Int](repeating: 0, count: 336)
        func smooth(_ lo: Double, _ hi: Double, _ value: Double) -> Double {
            let t = max(0, min(1, (value-lo)/(hi-lo)))
            return t*t*(3-2*t)
        }
        for y in 0..<thumbnail.height { for x in 0..<thumbnail.width {
            let xx = (Double(x)+0.5)/Double(thumbnail.width), yy = (Double(y)+0.5)/Double(thumbnail.height)
            guard bounds.contains(CGPoint(x: xx, y: yy)) else { continue }
            let p = (y*thumbnail.width+x)*3
            let rgb = (0..<3).map { Double(thumbnail.rgb[p+$0]) }
            let peak = rgb.max()!, low = rgb.min()!
            let light = 0.2126*rgb[0]+0.7152*rgb[1]+0.0722*rgb[2]
            if let surface = field.surface {
                let corrected = surfaceRGB(rgb,x: xx,y: yy,map: surface,global: global+(field.brightnessEV ?? 0))
                let col = min(23,Int((xx-bounds.minX)/bounds.width*24)), row = min(13,Int((yy-bounds.minY)/bounds.height*14))
                sums[row*24+col] += 0.2126*corrected[0]+0.7152*corrected[1]+0.0722*corrected[2]
                counts[row*24+col] += 1
                continue
            }
            let basis = SpatialField.basis(x: xx, y: yy, columns: field.columns, rows: field.rows)
            let local = basis.reduce(0) { $0+field.stops[$1.0]*$1.1 }
            let offset = basis.reduce(0) { $0+field.offsets[$1.0]*$1.1 }
            let exposure = basis.reduce(0) { $0+field.exposureStops[$1.0]*$1.1 }
            let exposureGain = pow(2, max(-2,min(2,global+exposure)))
            let toneGain = max(0,pow(2,max(-2,min(2,global+local)))+offset/max(0.001,light))
            let support = smooth(0.03,0.12,light)*(1-smooth(0.15,0.45,(peak-low)/max(0.001,peak)))
            var gain = exposureGain+(toneGain-exposureGain)*support
            if let brightness = field.brightnessEV {
                gain = max(exposureGain*pow(2,-0.5),min(exposureGain*pow(2,0.5),gain))
                gain = pow(2,max(-2,min(2,log2(max(0.000001,gain))+brightness+basis.reduce(0) { $0+(field.validationStops?[$1.0] ?? 0)*$1.1 })))
            }
            if gain > 1, peak > 0 { gain = min(gain,max(1,0.995/peak)) }
            let col = min(23,Int((xx-bounds.minX)/bounds.width*24))
            let row = min(13,Int((yy-bounds.minY)/bounds.height*14))
            let patch = row*24+col
            sums[patch] += light*gain; counts[patch] += 1
        } }
        return sums.indices.map { counts[$0] > 0 ? sums[$0]/Double(counts[$0]) : .nan }
    }
}
