import Foundation
import CoreGraphics
import CoreVideo
import Vision

/// Correspondence is measured after removing each channel's patch exposure.
/// Lighting changes therefore do not masquerade as object movement. Only
/// measurements move: rendering never warps or blends neighbouring images.
enum SurfaceTracking {
    // Experimental correspondence variants remain opt-in until broad encoded
    // tests establish that they preserve photometry as well as geometry.
    static let curvatureEnabled = ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_CURVATURE"] == "1"
    static let contrastTrackingEnabled = ProcessInfo.processInfo.environment["FRANKLUMA_CONTRAST_TRACKING"] != "0"
    static let subpixelEnabled = ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_SUBPIXEL"] == "1"
    struct Match: Sendable {
        let x: Int
        let y: Int
        let channelEV: [Double] // reference minus source, in linear-light stops
        let error: Double
        let confidence: Double
        var offsetX: Double = 0
        var offsetY: Double = 0
        var photometricConfidence: Double = 1
    }

    fileprivate struct Descriptor: Sendable {
        let mean: [Double]
        let texture: [Double]
        let energy: Double
        var curvature: [Double] = []
    }

    /// A moving illumination band adds smooth curvature even after planar
    /// exposure normalisation. Remove only a small, RGB-coherent quadratic
    /// nuisance from the descriptor difference, retaining texture itself.
    private static func textureError(_ a: Descriptor,_ b: Descriptor,half: Int,contrastInvariant: Bool) -> Double {
        var sum = 0.0
        for k in a.texture.indices { let d = a.texture[k]-b.texture[k];sum += d*d }
        // Contrast can change under diffuse/specular light without moving the
        // surface. Fit only a bounded scalar to already matching texture shape;
        // raw means remain untouched for the subsequent exposure measurement.
        if contrastInvariant,a.texture.count == (2*half+1)*(2*half+1)*3,
           a.energy > 0.03,b.energy > 0.03,
           (0.5...2).contains(b.energy/a.energy) {
            let dot = zip(a.texture,b.texture).reduce(0.0) { $0+$1.0*$1.1 }
            let correlation = dot/(Double(a.texture.count)*a.energy*b.energy)
            if correlation > 0.95 {
                return sqrt(max(0,2*(1-min(1,correlation))*a.energy*b.energy))
            }
        }
        guard curvatureEnabled,
              a.texture.count == (2*half+1)*(2*half+1)*3,half == 2 else { return sqrt(sum/Double(a.texture.count)) }
        guard a.curvature.count == 9,b.curvature.count == 9 else { return sqrt(sum/Double(a.texture.count)) }
        let denominators = [70.0,70.0,100.0]
        for j in 0..<3 {
            let values = (0..<3).map { a.curvature[$0*3+j]-b.curvature[$0*3+j] }
            guard values.max()!-values.min()! < 0.004 else { continue }
            let nuisance = max(-0.015,min(0.015,ExposureMath.median(values)))
            sum += denominators[j]*(3*nuisance*nuisance-2*nuisance*values.reduce(0,+))
        }
        return sqrt(max(0,sum)/Double(a.texture.count))
    }

    fileprivate static func descriptor(_ image: SpatialThumbnail, x: Int, y: Int, half: Int) -> Descriptor? {
        descriptor(image,x: Double(x),y: Double(y),half: half)
    }

    fileprivate static func descriptor(_ image: SpatialThumbnail, x: Double, y: Double, half: Int) -> Descriptor? {
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
        var curvature = [Double](repeating: 0,count: 9)
        if half == 2 {
            var index = 0
            for dy in -half...half { for dx in -half...half {
                let basis = [Double(dx*dx)-2,Double(dy*dy)-2,Double(dx*dy)]
                for c in 0..<3 {
                    for j in 0..<3 { curvature[c*3+j] += texture[index]*basis[j]/(j == 2 ? 100 : 70) }
                    index += 1
                }
            } }
        }
        return Descriptor(mean: means,texture: texture,energy: energy,curvature: curvature)
    }

    /// Stationary evidence needs visible structure, not merely the same colour.
    /// Flat neutral objects and backgrounds have ambiguous identity and supply
    /// no independent lighting measurement through this fallback.
    static func stationaryConfidence(_ source: SpatialThumbnail, _ reference: SpatialThumbnail,
                                     x: Int, y: Int, half: Int = 6) -> Double {
        guard let a = descriptor(source,x: x,y: y,half: half),
              let b = descriptor(reference,x: x,y: y,half: half) else { return 0 }
        return stationaryConfidence(a,b)
    }

    fileprivate static func stationaryConfidence(_ a: Descriptor, _ b: Descriptor) -> Double {
        guard a.energy > 0.03, b.energy > 0.03 else { return 0 }
        let error = sqrt(zip(a.texture,b.texture).reduce(0) { $0+pow($1.0-$1.1,2) }/Double(a.texture.count))
        return error < 0.08 ? 0.65*(1-error/0.08) : 0
    }

    /// Fixed-footprint identity under changing contrast. This only certifies
    /// geometry; raw central RGB means still determine the exposure history.
    static func stationaryContrastConfidence(_ source: SpatialThumbnail,_ reference: SpatialThumbnail,
                                             x: Int,y: Int,half: Int = 6) -> Double {
        guard let a = descriptor(source,x: x,y: y,half: half),
              let b = descriptor(reference,x: x,y: y,half: half) else { return 0 }
        return stationaryContrastConfidence(a,b,half: half)
    }

    fileprivate static func stationaryContrastConfidence(_ a: Descriptor,_ b: Descriptor,half: Int = 6) -> Double {
        guard a.energy > 0.03,b.energy > 0.03,(0.5...2).contains(b.energy/a.energy) else { return 0 }
        let correlation = zip(a.texture,b.texture).reduce(0.0) { $0+$1.0*$1.1 }/(Double(a.texture.count)*a.energy*b.energy)
        guard correlation > 0.98 else { return 0 }
        let error = textureError(a,b,half: half,contrastInvariant: true)
        return error < 0.08 ? 0.65*(1-error/0.08) : 0
    }

    /// Geometry proof only: contrast changes can alter texture amplitude while
    /// leaving its spatial shape intact. This does not change the raw RGB
    /// measurements used to estimate exposure or introduce image warping.
    static func stationaryShapeConfidence(_ source: SpatialThumbnail,_ reference: SpatialThumbnail,
                                          x: Int,y: Int,half: Int = 6) -> Double {
        guard let a = descriptor(source,x: x,y: y,half: half),
              let b = descriptor(reference,x: x,y: y,half: half),a.energy > 0.03,b.energy > 0.03 else { return 0 }
        let correlation = zip(a.texture,b.texture).reduce(0.0) { $0+$1.0*$1.1 }/Double(a.texture.count)/a.energy/b.energy
        return max(0,min(1,(correlation-0.9)/0.1))
    }

    /// Source geometry diagnostic at two camera-predicted integer positions.
    /// Nil means missing or textureless evidence, not a stationary camera.
    static func cameraShapeCorrelation(_ source: SpatialThumbnail,_ reference: SpatialThumbnail,
                                       x: Int,y: Int,referenceX: Int,referenceY: Int,half: Int = 6) -> Double? {
        guard (6...12).contains(half),let a = descriptor(source,x:x,y:y,half:half),
              let b = descriptor(reference,x:referenceX,y:referenceY,half:half),
              a.energy > 0.03,b.energy > 0.03 else { return nil }
        return zip(a.texture,b.texture).reduce(0,{ $0+$1.0*$1.1 })/(Double(a.texture.count)*a.energy*b.energy)
    }

    /// Measurement-only dense correspondence. Source/renderer pixels are never
    /// replaced. Native flow must close reciprocally at every measured pixel.
    static func flowTransportedPixels(_ source: SpatialThumbnail,_ reference: SpatialThumbnail,
                                      flow: SurfaceMotion.Flow,x: Int,y: Int,half: Int = 2,
                                      geometryHalf: Int = 6,maximumDisplacement: Double = 2,measurementReference: SpatialThumbnail? = nil) -> (pixels:[Double],points:[(x:Double,y:Double)],maximumDisplacement:Double)? {
        guard (1...6).contains(half),(6...12).contains(geometryHalf),
              maximumDisplacement.isFinite,maximumDisplacement > 0,
              source.width == reference.width,source.height == reference.height,
              flow.width == source.width,flow.height == source.height,flow.spacing == 1,flow.origin == 0,
              source.rgb.count == source.width*source.height*3,reference.rgb.count == reference.width*reference.height*3,
              let center = flow.prediction(Double(x),Double(y)),
              let a = descriptor(source,x:x,y:y,half:geometryHalf),
              let b = descriptor(reference,x:center.0,y:center.1,half:geometryHalf),
              a.energy > 0.03,b.energy > 0.03 else { return nil }
        let correlation = zip(a.texture,b.texture).reduce(0.0) { $0+$1.0*$1.1 }/(Double(a.texture.count)*a.energy*b.energy)
        guard correlation > 0.95 else { return nil }
        let measured = measurementReference ?? reference
        guard measured.width == reference.width,measured.height == reference.height,measured.rgb.count == reference.rgb.count else { return nil }
        var result = [Double](),positions = [(x:Double,y:Double)](),largest = 0.0
        for dy in -half...half { for dx in -half...half {
            let sx = Double(x+dx),sy = Double(y+dy)
            guard let point = flow.prediction(sx,sy) else { return nil }
            let displacement = hypot(point.0-sx,point.1-sy)
            guard displacement <= maximumDisplacement,point.0 >= 0,point.1 >= 0,
                  point.0 < Double(reference.width-1),point.1 < Double(reference.height-1) else { return nil }
            largest = max(largest,displacement)
            positions.append((point.0,point.1))
            let ix = Int(floor(point.0)),iy = Int(floor(point.1)),fx = point.0-Double(ix),fy = point.1-Double(iy)
            for c in 0..<3 {
                let p = (iy*reference.width+ix)*3+c
                let top = Double(measured.rgb[p])*(1-fx)+Double(measured.rgb[p+3])*fx
                let bottom = Double(measured.rgb[p+reference.width*3])*(1-fx)+Double(measured.rgb[p+reference.width*3+3])*fx
                let value = top*(1-fy)+bottom*fy
                guard value.isFinite else { return nil }
                result.append(value)
            }
        } }
        return (result,positions,largest)
    }

    /// Diagnostic refinement around a camera-predicted position. Uses the
    /// wider geometry footprint, never the held lighting error as an objective.
    static func cameraRefinedPoint(_ source: SpatialThumbnail,_ reference: SpatialThumbnail,
                                   x: Double,y: Double,referenceX: Double,referenceY: Double,
                                   minimumImprovement: Double = 0.01,
                                   diagnostic: ((String,[String:Double]) -> Void)? = nil) -> (Double,Double)? {
        guard minimumImprovement.isFinite,(0.0001...0.05).contains(minimumImprovement) else { return nil }
        func search(_ stage: String,_ aImage: SpatialThumbnail,_ bImage: SpatialThumbnail,_ ax: Double,_ ay: Double,_ bx: Double,_ by: Double) -> (Double,Double,Double)? {
            guard let a = descriptor(aImage,x:ax,y:ay,half:6),a.energy > 0.03 else { return nil }
            func correlation(_ px: Double,_ py: Double) -> Double? {
                guard let b = descriptor(bImage,x:px,y:py,half:6),b.energy > 0.03 else { return nil }
                return zip(a.texture,b.texture).reduce(0,{ $0+$1.0*$1.1 })/(Double(a.texture.count)*a.energy*b.energy)
            }
            guard let initial = correlation(bx,by) else { return nil }
            var best = (bx,by,initial)
            for step in [1.0,0.5,0.25] {
                let center = best
                for dy in [-step,0,step] { for dx in [-step,0,step] {
                    let px = center.0+dx,py = center.1+dy
                    guard abs(px-bx) <= 1,abs(py-by) <= 1,
                          let score = correlation(px,py),score > best.2+1e-6 else { continue }
                    best = (px,py,score)
                } }
            }
            diagnostic?(stage,["initialCorrelation":initial,"proposedCorrelation":best.2,
                "improvement":best.2-initial,"proposedX":best.0,"proposedY":best.1,
                "cameraX":bx,"cameraY":by,"minimumImprovement":minimumImprovement,
                "acceptedMovement":best.2 > 0.95 && best.2-initial >= minimumImprovement ? 1 : 0])
            guard best.2 > 0.95 else { return nil }
            // Preserve camera coordinates when improvement is insignificant.
            if best.2-initial >= minimumImprovement { return best }
            return initial > 0.95 ? (bx,by,initial) : nil
        }
        guard let forward = search("forward",source,reference,x,y,referenceX,referenceY),
              let reverse = search("reverse",reference,source,forward.0,forward.1,x,y),
              hypot(reverse.0-x,reverse.1-y) <= 0.5 else { return nil }
        return (forward.0,forward.1)
    }

    struct Prepared: Sendable {
        let width: Int
        let height: Int
        let half: Int
        fileprivate let image: SpatialThumbnail
        fileprivate let descriptors: [Descriptor?]
        init(_ image: SpatialThumbnail, half: Int = 2) {
            width = image.width; height = image.height; self.half = half; self.image = image
            descriptors = (0..<(width * height)).map { pixel in
                let x = pixel % image.width,y = pixel / image.width
                guard let local = SurfaceTracking.descriptor(image,x: x,y: y,half: half) else { return nil }
                // A flat centre may still belong to a trackable object whose
                // silhouette is visible in a wider neighbourhood. Track that
                // structure, but measure lighting only in the central patch.
                if local.energy < 0.03,
                   let wide = SurfaceTracking.descriptor(image,x: x,y: y,half: max(half,6)),wide.energy > 0.06 {
                    return Descriptor(mean: local.mean,texture: wide.texture.map { $0/wide.energy },energy: wide.energy)
                }
                return local
            }
        }
        fileprivate func at(_ x: Int, _ y: Int) -> Descriptor? {
            guard x >= 0, y >= 0, x < width, y < height else { return nil }
            return descriptors[y * width + x]
        }
        func lighting(x: Int,y: Int) -> [Double]? { at(x,y)?.mean }
        func neutralSupport(x: Int,y: Int,offsetX: Double = 0,offsetY: Double = 0) -> Double? {
            guard SurfaceTracking.contrastPhotometryEnabled else { return nil }
            return SurfaceTracking.neutralTextureSupport(image,x: Double(x)+offsetX,y: Double(y)+offsetY)
        }
        func neutralSupport(_ match: Match) -> Double? {
            neutralSupport(x: match.x,y: match.y,offsetX: match.offsetX,offsetY: match.offsetY)
        }

        fileprivate func at(_ x: Int,_ y: Int,offsetX: Double,offsetY: Double) -> Descriptor? {
            if offsetX == 0 && offsetY == 0 { return at(x,y) }
            return SurfaceTracking.descriptor(image,x: Double(x)+offsetX,y: Double(y)+offsetY,half: half)
        }
        func lighting(_ match: Match) -> [Double]? {
            at(match.x,match.y,offsetX: match.offsetX,offsetY: match.offsetY)?.mean
        }
    }

    private static func search(_ source: Prepared, _ reference: Prepared,
                               x: Int, y: Int, radius: Int, predicted: (Double, Double)? = nil,
                               offsetX: Double = 0,offsetY: Double = 0,subpixel: Bool = subpixelEnabled,contrastInvariant: Bool = contrastTrackingEnabled) -> Match? {
        guard let a = source.at(x,y,offsetX: offsetX,offsetY: offsetY), a.energy > 0.018 else { return nil }
        var wideSource: Descriptor?
        var preparedWide = false
        func correspondenceEvidence(_ b: Descriptor,x: Double,y: Double) -> (error: Double,photometricConfidence: Double) {
            let raw = textureError(a,b,half: source.half,contrastInvariant: false)
            guard contrastInvariant else { return (raw,1) }
            let normalized = textureError(a,b,half: source.half,contrastInvariant: true)
            guard raw-normalized > 0.005 else { return (raw,1) }
            if !preparedWide {
                wideSource = descriptor(source.image,x: Double(xOriginal)+offsetX,y: Double(yOriginal)+offsetY,half: 6)
                preparedWide = true
            }
            guard let wideA = wideSource,
                  let wideB = descriptor(reference.image,x: x,y: y,half: 6),
                  wideA.energy > 0.03,wideB.energy > 0.03,
                  (0.5...2).contains(wideB.energy/wideA.energy) else { return (raw,1) }
            let correlation = zip(wideA.texture,wideB.texture).reduce(0.0) { $0+$1.0*$1.1 } / (Double(wideA.texture.count)*wideA.energy*wideB.energy)
            guard correlation > 0.98 else { return (raw,1) }
            return (normalized,max(0,min(1,(1-raw/0.18)/max(0.000001,1-normalized/0.18))))
        }
        let xOriginal = x,yOriginal = y
        var best: Match?, bestScore = Double.infinity
        let cx = predicted.map { Int($0.0.rounded()) } ?? x
        let cy = predicted.map { Int($0.1.rounded()) } ?? y
        for dy in -radius...radius { for dx in -radius...radius {
            guard let b = reference.at(cx+dx,cy+dy),b.texture.count == a.texture.count else { continue }
            let evidence = correspondenceEvidence(b,x: Double(cx+dx),y: Double(cy+dy))
            let error = evidence.error
            let score = error + 0.0015 * Double(dx*dx+dy*dy)
            if score < bestScore {
                bestScore = score
                let confidence = max(0, 1-error/0.18) * min(1, min(a.energy,b.energy)/0.06)
                best = Match(x: cx+dx, y: cy+dy, channelEV: zip(b.mean,a.mean).map(-), error: error, confidence: confidence,photometricConfidence: evidence.photometricConfidence)
            }
        } }
        guard var refined = best else { return nil }
        // Refine only a structured central patch. Wider silhouette descriptors
        // identify flat interiors but cannot establish subpixel photometry.
        if subpixel,
           radius > 0, refined.error > 0.005, a.texture.count == (2*source.half+1)*(2*source.half+1)*3 {
            var px = Double(refined.x),py = Double(refined.y)
            for step in [0.5,0.25] {
                let centreX = px,centreY = py
                for dy in [-step,0,step] { for dx in [-step,0,step] {
                    let xx = centreX+dx,yy = centreY+dy
                    guard let b = descriptor(reference.image,x: xx,y: yy,half: reference.half),b.texture.count == a.texture.count else { continue }
                    let evidence = correspondenceEvidence(b,x: xx,y: yy)
                    let error = evidence.error
                    guard error < refined.error-0.00001 else { continue }
                    let confidence = max(0,1-error/0.18)*min(1,min(a.energy,b.energy)/0.06)
                    let ix = Int(xx.rounded()),iy = Int(yy.rounded())
                    refined = Match(x: ix,y: iy,channelEV: zip(b.mean,a.mean).map(-),error: error,confidence: confidence,
                        offsetX: xx-Double(ix),offsetY: yy-Double(iy),photometricConfidence: evidence.photometricConfidence)
                    px = xx;py = yy
                } }
            }
        }
        // A tiny improvement can be caused by changing illumination curvature
        // rather than movement. Preserve the integer correspondence unless
        // fractional alignment supplies substantially better texture evidence.
        return best.map { refined.error < $0.error*0.75 ? refined : $0 } ?? refined
    }

    /// Reject disocclusions and uncertain patches with a reverse correspondence.
    static func match(_ source: Prepared, _ reference: Prepared,
                      x: Int, y: Int, radius: Int = 8, motion: SurfaceMotion.Model? = nil,flow: SurfaceMotion.Flow? = nil,
                      offsetX: Double = 0,offsetY: Double = 0,subpixel: Bool = subpixelEnabled,contrastInvariant: Bool = contrastTrackingEnabled) -> Match? {
        guard source.width == reference.width, source.height == reference.height, source.half == reference.half else { return nil }
        func checked(_ prediction: (Double,Double)?, guided: Bool) -> Match? {
            guard let forward = search(source,reference,x: x,y: y,radius: radius,predicted: prediction,offsetX: offsetX,offsetY: offsetY,subpixel: subpixel,contrastInvariant: contrastInvariant),forward.confidence > 0.3,
                  let reverse = search(reference,source,x: forward.x,y: forward.y,radius: radius,
                    predicted: guided ? motion?.inverse(Double(forward.x)+forward.offsetX,Double(forward.y)+forward.offsetY) : nil,
                    offsetX: forward.offsetX,offsetY: forward.offsetY,subpixel: subpixel,contrastInvariant: contrastInvariant),reverse.confidence > 0.3,
                  abs(Double(reverse.x-x)+reverse.offsetX-offsetX) <= 1,abs(Double(reverse.y-y)+reverse.offsetY-offsetY) <= 1 else { return nil }
            return forward
        }
        let local = checked(nil,guided: false)
        var result = local
        if let motion {
            let predicted = motion.point(Double(x)+offsetX,Double(y)+offsetY)
            if hypot(predicted.0-Double(x),predicted.1-Double(y)) >= 1,
               let guided = checked(predicted,guided: true) {
                result = local.map { ($0.error > 0.06 && guided.error < $0.error*0.6) ? guided : $0 } ?? guided
            }
        }
        // Flow supplies a local search centre only after a tight independent
        // forward/backward cycle check. Raw exposure and texture checks remain.
        if let flow,result == nil || result!.error > 0.06,
           let prediction = flow.prediction(Double(x)+offsetX,Double(y)+offsetY),
           let forward = search(source,reference,x: x,y: y,radius: 2,predicted: prediction,
                offsetX: offsetX,offsetY: offsetY,subpixel: true,contrastInvariant: contrastInvariant),forward.confidence > 0.3,
           let reversePrediction = flow.inverse(Double(forward.x)+forward.offsetX,Double(forward.y)+forward.offsetY),
           let reverse = search(reference,source,x: forward.x,y: forward.y,radius: 2,predicted: reversePrediction,
                offsetX: forward.offsetX,offsetY: forward.offsetY,subpixel: true,contrastInvariant: contrastInvariant),reverse.confidence > 0.3,
           hypot(Double(reverse.x-x)+reverse.offsetX-offsetX,Double(reverse.y-y)+reverse.offsetY-offsetY) < 0.5 {
            result = result.map { forward.error < $0.error*0.6 ? forward : $0 } ?? forward
        }
        return result
    }

    /// A local illumination hypothesis can differ from the scene's exposure.
    /// Confirm identity on a wider footprint using unscaled log texture, and
    /// reject clipping/contrast changes rather than requiring global agreement.
    static func localMeasurementIdentity(_ source: Prepared, _ reference: Prepared,
                                         point: Observation, match: Match) -> Double {
        guard match.confidence >= 0.9,match.photometricConfidence >= 0.9,
              let a = descriptor(source.image,x: Double(point.x)+point.offsetX,y: Double(point.y)+point.offsetY,half: 6),
              let b = descriptor(reference.image,x: Double(match.x)+match.offsetX,y: Double(match.y)+match.offsetY,half: 6),
              a.energy > 0.03,b.energy > 0.03,
              (0.8...1.25).contains(b.energy/a.energy),
              a.mean.allSatisfy({ $0 < log2(0.8) }),b.mean.allSatisfy({ $0 < log2(0.8) }) else { return 0 }
        let correlation = zip(a.texture,b.texture).reduce(0.0) { $0+$1.0*$1.1 }/(Double(a.texture.count)*a.energy*b.energy)
        guard correlation > 0.995,textureError(a,b,half: 6,contrastInvariant: false) < 0.02 else { return 0 }
        return 1
    }

    static func match(_ source: SpatialThumbnail, _ reference: SpatialThumbnail,
                      x: Int, y: Int, radius: Int = 8, half: Int = 2) -> Match? {
        match(Prepared(source, half: half), Prepared(reference, half: half), x: x, y: y, radius: radius)
    }

    static var contrastPhotometryEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_CONTRAST_PHOTOMETRY"] == "1" }

    /// Under neutral illumination, the component perpendicular to the grey
    /// axis retains material colour while cancelling additive neutral highlights.
    static func colourContrast(_ levels: [Double]) -> (level: Double,direction: [Double],saturation: Double)? {
        guard levels.count == 3,levels.allSatisfy(\.isFinite) else { return nil }
        let rgb = levels.map { pow(2,$0) },grey = rgb.reduce(0,+)/3
        let colour = rgb.map { $0-grey },norm = sqrt(colour.reduce(0) { $0+$1*$1 })
        guard norm > 0.02,grey > 0,norm/grey > 0.12 else { return nil }
        return (log2(norm),colour.map { $0/norm },norm/grey)
    }

    static func neutralTextureSupport(_ image: SpatialThumbnail,x: Double,y: Double) -> Double? {
        guard x >= 2,y >= 2,x+2 < Double(image.width-1),y+2 < Double(image.height-1) else { return nil }
        let ix = Int(x),iy = Int(y),fx = x-Double(ix),fy = y-Double(iy)
        var samples: [[Double]] = [],means = [Double](repeating: 0,count: 3)
        for dy in -2...2 { for dx in -2...2 {
            let p = ((iy+dy)*image.width+ix+dx)*3
            var rgb = [Double](repeating: 0,count: 3)
            for c in 0..<3 {
                let top = Double(image.rgb[p+c])*(1-fx)+Double(image.rgb[p+3+c])*fx
                let bottom = Double(image.rgb[p+image.width*3+c])*(1-fx)+Double(image.rgb[p+image.width*3+3+c])*fx
                rgb[c] = top*(1-fy)+bottom*fy
                means[c] += rgb[c]/25
            }
            guard rgb.min()! > 0.015,rgb.max()! < 0.8 else { return nil }
            samples.append(rgb)
        } }
        let grey = means.reduce(0,+)/3
        var energy = 0.0,neutral = 0.0
        for rgb in samples {
            energy += (0..<3).reduce(0) { $0+pow(rgb[$1]-means[$1],2) }
            neutral += 3*pow(rgb.reduce(0,+)/3-grey,2)
        }
        guard energy > 25*3*0.000001 else { return nil }
        return max(0,min(1,neutral/energy))
    }

    static func contrastHistory(_ track: [Observation]) -> [Observation] {
        guard track.count >= 4,!track.contains(where: { $0.usesContrastPhotometry }),
              track.allSatisfy({ ($0.channelLevels.max() ?? 0) < log2(0.75) && ($0.neutralTextureConfidence ?? 0) >= 0.9 }) else { return track }
        let measurements = track.compactMap { colourContrast($0.channelLevels) }
        guard measurements.count == track.count,
              measurements.allSatisfy({ $0.level > log2(0.08) && $0.saturation > 0.75 }) else { return track }
        var chromaticEnergy = 0.0
        for i in 1..<track.count {
            let change = zip(track[i].channelLevels,track[i-1].channelLevels).map(-)
            let common = change.reduce(0,+)/3
            chromaticEnergy += change.reduce(0) { $0+pow($1-common,2) }
        }
        guard chromaticEnergy/Double((track.count-1)*3) > 0.01*0.01 else { return track }
        let direction = (0..<3).map { c in ExposureMath.median(measurements.map { $0.direction[c] }) }
        let spread = measurements.map { value in sqrt((0..<3).reduce(0) { $0+pow(value.direction[$1]-direction[$1],2) }) }
        guard (spread.max() ?? 1) < 0.025 else { return track }
        let reflectance = (0..<3).map { c in ExposureMath.median(zip(track,measurements).map { $0.0.channelLevels[c]-$0.1.level }) }
        return zip(track,measurements).map { point,measurement in
            Observation(frame: point.frame,x: point.x,y: point.y,channelLevels: reflectance.map { $0+measurement.level },
                confidence: point.confidence,neutralTextureConfidence: point.neutralTextureConfidence,usesContrastPhotometry: true,sourcePeakLevel: point.channelLevels.max(),
                offsetX: point.offsetX,offsetY: point.offsetY)
        }
    }

    struct Observation: Sendable {
        let frame: Int
        let x: Int
        let y: Int
        let channelLevels: [Double]
        let confidence: Double
        var neutralTextureConfidence: Double? = nil
        var usesContrastPhotometry: Bool = false
        var sourcePeakLevel: Double? = nil
        var offsetX: Double = 0
        var offsetY: Double = 0
    }

    struct LightingEstimate: Sendable {
        let frame: Int
        let x: Int
        let y: Int
        let channelEV: [Double]
        let confidence: Double
        var protectsFromGlobal: Bool = false
        var usesSharedExposure: Bool = false
        var usesContrastPhotometry: Bool = false
        var offsetX: Double = 0
        var offsetY: Double = 0
    }

    /// Solve the exposure history of one physical surface jointly. Each colour
    /// channel has its own multiplicative illumination estimate; there is no
    /// additive contrast fit which could change a moving object's texture.
    /// The temporal solver preserves gradual ramps in Smooth mode and uses a
    /// robust constant target in Steady mode. No correction is inferred from
    /// a trajectory too short to establish a temporal lighting baseline.
    static func lighting(_ rawObservations: [Observation], times: [Double], radius: Double,
                         mode: NormalisationMode, strength: Double, global: [Double] = [],
                         contrastPhotometry: Bool = contrastPhotometryEnabled,
                         confidenceTargets: Bool = ProcessInfo.processInfo.environment["FRANKLUMA_CONFIDENCE_TARGETS"] == "1") -> [LightingEstimate] {
        let observations = contrastPhotometry ? contrastHistory(rawObservations) : rawObservations
        guard observations.count >= 4, observations.allSatisfy({ times.indices.contains($0.frame) && $0.channelLevels.count == 3 }),
              zip(observations, observations.dropFirst()).allSatisfy({ times[$0.frame] < times[$1.frame] }) else { return [] }
        let amount = max(0,min(1,strength))
        let shared = global.count == times.count && amount > 0 && global.allSatisfy(\.isFinite) ? observations.map { global[$0.frame]/amount } : []
        func supported(_ point: Observation) -> Bool { point.confidence.isFinite && point.confidence > 0 }
        let trusted = confidenceTargets ? observations.filter(supported) : observations
        let evidenceEdges = (1..<observations.count).filter {
            !confidenceTargets || (supported(observations[$0-1]) && supported(observations[$0]))
        }
        // Align fragmented tracks to the scene's shared exposure only when
        // all RGB channels independently follow its measured rapid changes.
        // An unchanged foreground under background flashes must keep its own
        // lighting baseline instead of inheriting the background correction.
        var coherent = false
        if shared.count == observations.count, observations.count >= 6,evidenceEdges.count >= 5 {
            let changes = evidenceEdges.map { -(shared[$0]-shared[$0-1]) }
            let energy = changes.reduce(0) { $0+$1*$1 }
            let distinct = changes.filter { abs($0) > 0.08 }
            let reversals = zip(distinct,distinct.dropFirst()).filter { $0*$1 < 0 }.count
            // One appearance jump during a pan is insufficient evidence of
            // shared flicker. Repeated rises and falls establish that evidence.
            if distinct.count >= 2, reversals >= 1, energy/Double(changes.count) > 0.005 {
                coherent = (0..<3).allSatisfy { channel in
                    let measured = evidenceEdges.map { observations[$0].channelLevels[channel]-observations[$0-1].channelLevels[channel] }
                    let slope = zip(measured,changes).reduce(0) { $0+$1.0*$1.1 }/energy
                    let error = zip(measured,changes).reduce(0) { $0+abs($1.0-$1.1) }/Double(changes.count)
                    return (0.65...1.35).contains(slope) && error < 0.08
                }
            }
        }
        let curves = (0..<3).map { channel in
            if confidenceTargets {
                let levels = observations.map { $0.channelLevels[channel]+(coherent ? global[$0.frame]/amount : 0) }
                // Matching confidence is not a calibrated variance estimate.
                // Exclude explicitly unsupported measurements without giving
                // brighter or more textured frames disproportionate target votes.
                let weights = observations.map { $0.confidence.isFinite && $0.confidence > 0 ? 1.0 : 0.0 }
                guard weights.contains(where: { $0 > 0 }) else { return Array(repeating: 0.0,count: levels.count) }
                let target = mode == .steady ? Array(repeating: ExposureMath.weightedMedian(levels,weights: weights),count: levels.count)
                    : ExposureMath.smoothTargets(times: observations.map { times[$0.frame] },levels: levels,radius: radius,reliability: weights)
                return zip(target,levels).map { max(-2,min(2,$0-$1))*amount }
            }
            return ExposureMath.curve(samples: observations.map {
                ExposureSample(time: times[$0.frame], level: $0.channelLevels[channel]+(coherent ? global[$0.frame]/amount : 0), segment: 0)
            }, radius: radius, strength: amount, mode: mode).stops
        }
        var protectsFromGlobal = false
        if shared.count == observations.count,trusted.count >= 8,evidenceEdges.count >= 7,
           trusted.allSatisfy({ ($0.sourcePeakLevel ?? $0.channelLevels.max() ?? 0) < log2(0.8) }) {
            let changes = evidenceEdges.map { shared[$0]-shared[$0-1] }
            let energy = changes.reduce(0) { $0+$1*$1 }
            if energy/Double(changes.count) > 0.0004 {
                protectsFromGlobal = (0..<3).allSatisfy { channel in
                    let measured = evidenceEdges.map { observations[$0].channelLevels[channel]-observations[$0-1].channelLevels[channel] }
                    return measured.reduce(0) { $0+$1*$1 } < energy*0.10
                        && ExposureMath.median(measured.map(abs)) < 0.025
                }
            }
        }
        return observations.enumerated().map { index, observation in
            LightingEstimate(frame: observation.frame, x: observation.x, y: observation.y,
                channelEV: curves.map { max(-2,min(2,$0[index]+(coherent ? global[observation.frame] : 0))) }, confidence: observation.confidence,
                protectsFromGlobal: protectsFromGlobal,usesSharedExposure: coherent,usesContrastPhotometry: observation.usesContrastPhotometry,offsetX: observation.offsetX,offsetY: observation.offsetY)
        }
    }

    /// Follow a visible surface in both directions from the frame being examined.
    /// Each direction terminates independently at the existing cut/identity checks.
    /// Earlier occlusion must not suppress a newly visible surface's valid history.
    static func trajectoryThrough(_ frames: [Prepared], segments: [Int], anchor: Int,
                                  x: Int, y: Int, radius: Int = 8) -> [Observation] {
        guard frames.count == segments.count,frames.indices.contains(anchor) else { return [] }
        let forward = trajectory(frames,segments:segments,start:anchor,x:x,y:y,radius:radius)
        guard !forward.isEmpty else { return [] }
        let backward = trajectory(Array(frames.reversed()),segments:Array(segments.reversed()),
                                  start:frames.count-1-anchor,x:x,y:y,radius:radius)
        let earlier = backward.dropFirst().reversed().map { point in
            Observation(frame:frames.count-1-point.frame,x:point.x,y:point.y,
                        channelLevels:point.channelLevels,confidence:point.confidence,
                        neutralTextureConfidence:point.neutralTextureConfidence,
                        offsetX:point.offsetX,offsetY:point.offsetY)
        }
        return earlier+forward
    }

    /// A trajectory terminates at a cut, disocclusion, or uncertain match.
    /// A later visible surface starts a fresh trajectory rather than inheriting
    /// the exposure history of the object which previously occupied its pixels.
    static func trajectory(_ frames: [Prepared], segments: [Int], start: Int,
                           x: Int, y: Int, radius: Int = 8) -> [Observation] {
        guard frames.count == segments.count, frames.indices.contains(start),
              let first = frames[start].at(x,y) else { return [] }
        var result = [Observation(frame: start, x: x, y: y, channelLevels: first.mean, confidence: 1,neutralTextureConfidence: frames[start].neutralSupport(x: x,y: y))]
        var px = x, py = y,offsetX = 0.0,offsetY = 0.0
        if start+1 < frames.count {
            for i in (start+1)..<frames.count {
                if Task.isCancelled || segments[i] != segments[i-1] { break }
                guard let match = match(frames[i-1], frames[i], x: px, y: py, radius: radius,offsetX: offsetX,offsetY: offsetY),
                      let levels = frames[i].lighting(match) else { break }
                px = match.x; py = match.y
                offsetX = match.offsetX;offsetY = match.offsetY
                result.append(Observation(frame: i, x: px, y: py, channelLevels: levels, confidence: match.confidence*match.photometricConfidence,neutralTextureConfidence: frames[i].neutralSupport(match),offsetX: offsetX,offsetY: offsetY))
            }
        }
        return result
    }

}

/// A coarse, robust camera model guides fine surface searches through rotation,
/// zoom and larger translations. It supplies coordinates, never rendered pixels.
enum SurfaceMotion {
    struct Flow: Sendable, Codable {
        let width: Int
        let height: Int
        let forward: [Float]
        let backward: [Float]
        var spacing: Double = 1
        var origin: Double = 0
        private func vector(_ values: [Float],_ x: Double,_ y: Double) -> (Double,Double)? {
            guard spacing.isFinite,spacing > 0,origin.isFinite else { return nil }
            let gx = (x-origin)/spacing,gy = (y-origin)/spacing
            guard gx.isFinite,gy.isFinite,gx >= 0,gy >= 0,gx < Double(width-1),gy < Double(height-1),
                  values.count == width*height*2 else { return nil }
            let ix = Int(gx),iy = Int(gy),fx = gx-Double(ix),fy = gy-Double(iy)
            let p = (iy*width+ix)*2
            let result: [Double] = (0..<2).map { c in
                let top = Double(values[p+c])*(1-fx)+Double(values[p+2+c])*fx
                let bottom = Double(values[p+width*2+c])*(1-fx)+Double(values[p+width*2+2+c])*fx
                return top*(1-fy)+bottom*fy
            }
            guard result.allSatisfy(\.isFinite) else { return nil }
            return (result[0],result[1])
        }
        /// Keep a four-pixel grid in coarse-image coordinates. A coarse
        /// pixel averages two fine pixels; its physical centre is 2*x+0.5.
        func coarseGuidance(width coarseWidth: Int,height coarseHeight: Int) -> Flow? {
            guard width == coarseWidth*2,height == coarseHeight*2,spacing == 1,origin == 0,
                  coarseWidth.isMultiple(of: 4),coarseHeight.isMultiple(of: 4) else { return nil }
            let columns = coarseWidth/4,rows = coarseHeight/4
            func sample(_ values: [Float]) -> [Float]? {
                var result = [Float]();result.reserveCapacity(columns*rows*2)
                for y in 0..<rows { for x in 0..<columns {
                    guard let value = vector(values,Double(2+x*4)*2+0.5,Double(2+y*4)*2+0.5) else { return nil }
                    result += [Float(value.0/2),Float(value.1/2)]
                } }
                return result
            }
            guard let f = sample(forward),let b = sample(backward) else { return nil }
            return Flow(width: columns,height: rows,forward: f,backward: b,spacing: 4,origin: 2)
        }
        func prediction(_ x: Double,_ y: Double) -> (Double,Double)? {
            guard let v = vector(forward,x,y),let r = vector(backward,x+v.0,y+v.1),
                  hypot(v.0+r.0,v.1+r.1) < 0.25 else { return nil }
            return (x+v.0,y+v.1)
        }
        func inverse(_ x: Double,_ y: Double) -> (Double,Double)? {
            guard let v = vector(backward,x,y) else { return nil }
            return (x+v.0,y+v.1)
        }
    }

    // Native requests are serialized and their buffers released after each
    // pair. The flow is ephemeral guidance, not retained analysis or imagery.
    private static let flowLock = NSLock()
    static func opticalFlow(_ source: SpatialThumbnail,_ reference: SpatialThumbnail) -> Flow? {
        guard source.width == reference.width,source.height == reference.height,
              source.width >= 16,source.height >= 16 else { return nil }
        flowLock.lock();defer { flowLock.unlock() }
        guard !Task.isCancelled else { return nil }
        return try? autoreleasepool {
            func buffer(_ image: SpatialThumbnail) throws -> CVPixelBuffer {
                guard image.rgb.count == image.width*image.height*3,image.rgb.allSatisfy(\.isFinite) else { throw NSError(domain: "Flow",code: 1) }
                var result: CVPixelBuffer?
                guard CVPixelBufferCreate(kCFAllocatorDefault,image.width,image.height,kCVPixelFormatType_32BGRA,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&result) == kCVReturnSuccess,
                      let result else { throw NSError(domain: "Flow",code: 2) }
                CVPixelBufferLockBaseAddress(result,[]);defer { CVPixelBufferUnlockBaseAddress(result,[]) }
                let bytes = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(result)
                let centre = (0..<3).map { c in ExposureMath.median((0..<(image.width*image.height)).map {
                    log2(max(0.003,Double(image.rgb[$0*3+c])))
                }) }
                for y in 0..<image.height { for x in 0..<image.width {
                    for c in 0..<3 {
                        let value = 0.5+0.15*(log2(max(0.003,Double(image.rgb[(y*image.width+x)*3+c])))-centre[c])
                        bytes[y*stride+x*4+2-c] = UInt8((255*max(0,min(1,value))).rounded())
                    }
                    bytes[y*stride+x*4+3] = 255
                } }
                return result
            }
            let a = try buffer(source),b = try buffer(reference)
            func compute(_ from: CVPixelBuffer,_ to: CVPixelBuffer) throws -> [Float] {
                try autoreleasepool {
                    let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: to,options: [:])
                    request.revision = VNGenerateOpticalFlowRequestRevision1
                    request.computationAccuracy = .high
                    request.outputPixelFormat = kCVPixelFormatType_TwoComponent32Float
                    try VNImageRequestHandler(cvPixelBuffer: from,options: [:]).perform([request])
                    guard let result = request.results?.first?.pixelBuffer,
                          CVPixelBufferGetWidth(result) == source.width,CVPixelBufferGetHeight(result) == source.height else {
                        throw NSError(domain: "Flow",code: 3)
                    }
                    CVPixelBufferLockBaseAddress(result,.readOnly);defer { CVPixelBufferUnlockBaseAddress(result,.readOnly) }
                    let values = CVPixelBufferGetBaseAddress(result)!.assumingMemoryBound(to: Float.self)
                    let stride = CVPixelBufferGetBytesPerRow(result)/MemoryLayout<Float>.size
                    return (0..<source.height).flatMap { y in Array(UnsafeBufferPointer(start: values+y*stride,count: source.width*2)) }
                }
            }
            return Flow(width: source.width,height: source.height,forward: try compute(a,b),backward: try compute(b,a))
        }
    }

    struct Model: Sendable {
        let x: [Double]
        let y: [Double]
        func point(_ px: Double,_ py: Double) -> (Double,Double) {
            (x[0]*px+x[1]*py+x[2],y[0]*px+y[1]*py+y[2])
        }
        func inverse(_ px: Double,_ py: Double) -> (Double,Double)? {
            let determinant = x[0]*y[1]-x[1]*y[0]
            guard abs(determinant) > 0.2 else { return nil }
            let a = px-x[2],b = py-y[2]
            return ((y[1]*a-x[1]*b)/determinant,(-y[0]*a+x[0]*b)/determinant)
        }
        var plausible: Bool {
            x.allSatisfy(\.isFinite) && y.allSatisfy(\.isFinite) &&
                (0.7...1.3).contains(x[0]) && (0.7...1.3).contains(y[1]) && abs(x[1]) < 0.25 && abs(y[0]) < 0.25
        }
    }
    private struct Pair {
        let x: Double, y: Double, u: Double, v: Double, confidence: Double
    }
    static func coarse(_ image: SpatialThumbnail) -> SurfaceTracking.Prepared {
        let w = image.width/2,h = image.height/2
        var rgb = [Float](repeating: 0,count: w*h*3)
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            for dy in 0..<2 { for dx in 0..<2 { rgb[(y*w+x)*3+c] += image.rgb[((y*2+dy)*image.width+x*2+dx)*3+c]/4 } }
        } } }
        return SurfaceTracking.Prepared(SpatialThumbnail(width: w,height: h,rgb: rgb))
    }
    private static func solve(_ matrix: [[Double]],_ right: [Double]) -> [Double]? {
        var a = zip(matrix,right).map { $0.0+[$0.1] }
        for col in 0..<3 {
            let pivot = (col..<3).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            guard abs(a[pivot][col]) > 0.000001 else { return nil }
            a.swapAt(col,pivot)
            let divisor = a[col][col]
            for j in col..<4 { a[col][j] /= divisor }
            for row in 0..<3 where row != col {
                let factor = a[row][col]
                for j in col..<4 { a[row][j] -= factor*a[col][j] }
            }
        }
        return a.map { $0[3] }
    }
    private static func fit(_ pairs: [Pair]) -> Model? {
        var normal = Array(repeating: Array(repeating: 0.0,count: 3),count: 3)
        var rx = [Double](repeating: 0,count: 3),ry = rx
        for p in pairs {
            let basis = [p.x,p.y,1]
            for i in 0..<3 {
                rx[i] += p.confidence*basis[i]*p.u;ry[i] += p.confidence*basis[i]*p.v
                for j in 0..<3 { normal[i][j] += p.confidence*basis[i]*basis[j] }
            }
        }
        guard let x = solve(normal,rx),let y = solve(normal,ry) else { return nil }
        let model = Model(x: x,y: y)
        return model.plausible ? model : nil
    }
    static func estimate(_ source: SurfaceTracking.Prepared,_ reference: SurfaceTracking.Prepared) -> Model? {
        guard source.width == reference.width,source.height == reference.height,source.width >= 16,source.height >= 12 else { return nil }
        var pairs: [Pair] = []
        for y in stride(from: 3,to: source.height-3,by: 4) { for x in stride(from: 3,to: source.width-3,by: 4) {
            guard let match = SurfaceTracking.match(source,reference,x: x,y: y,radius: 8,contrastInvariant: false) else { continue }
            pairs.append(Pair(x: Double(x),y: Double(y),u: Double(match.x),v: Double(match.y),confidence: match.confidence))
        } }
        guard pairs.count >= 12 else { return nil }
        var best: [Pair] = [],bestWeight = 0.0
        for i in 0..<min(96,pairs.count*2) {
            let n = pairs.count,indices = [i%n,(i*7+n/3+1)%n,(i*13+2*n/3+2)%n]
            guard Set(indices).count == 3,let model = fit(indices.map { pairs[$0] }) else { continue }
            let inliers = pairs.filter { p in let q = model.point(p.x,p.y);return hypot(q.0-p.u,q.1-p.v) < 1.25 }
            let weight = inliers.reduce(0) { $0+$1.confidence }
            if weight > bestWeight { best = inliers;bestWeight = weight }
        }
        guard best.count >= max(12,Int(ceil(Double(pairs.count)*0.6))),
              best.map(\.x).max()!-best.map(\.x).min()! >= Double(source.width)*0.5,
              best.map(\.y).max()!-best.map(\.y).min()! >= Double(source.height)*0.5,
              let model = fit(best) else { return nil }
        let support = best.reduce(0.0) { $0+$1.confidence }
        let identityError = sqrt(best.reduce(0.0) { $0+$1.confidence*(pow($1.u-$1.x,2)+pow($1.v-$1.y,2)) }/support)
        let modelError = sqrt(best.reduce(0.0) { sum,p in
            let q = model.point(p.x,p.y)
            return sum+p.confidence*(pow(q.0-p.u,2)+pow(q.1-p.v,2))
        }/support)
        // A flexible fit to quantisation noise must not label a stationary
        // camera as moving and disable the held-source brightness checks.
        guard identityError-modelError >= 0.2 else { return nil }
        let full = Model(x: [model.x[0],model.x[1],2*model.x[2]+0.5-0.5*(model.x[0]+model.x[1])],
                         y: [model.y[0],model.y[1],2*model.y[2]+0.5-0.5*(model.y[0]+model.y[1])])
        let corners = [(0.0,0.0),(Double(source.width*2),0.0),(0.0,Double(source.height*2)),(Double(source.width*2),Double(source.height*2))]
        guard corners.contains(where: { p in let q = full.point(p.0,p.1);return hypot(q.0-p.0,q.1-p.1) >= 1 }) else { return nil }
        return full
    }
}

struct SpatialThumbnail: Sendable, Codable {
    let width: Int
    let height: Int
    let rgb: [Float] // Same row order as the CI bitmap; display coordinates.
    var previousFlow: SurfaceMotion.Flow? = nil
    var light: [Double] {
        stride(from: 0, to: rgb.count, by: 3).map { 0.2126 * Double(rgb[$0]) + 0.7152 * Double(rgb[$0 + 1]) + 0.0722 * Double(rgb[$0 + 2]) }
    }
}

struct SpatialAlignment: Sendable, Codable {
    let reference: Int
    let dx: Int
    let dy: Int
    let error: Double
    let accepted: Bool
}

struct SpatialPatchTone: Sendable, Codable, Equatable {
    var stops: [Double]
    var offsets: [Double]
    var red: [Double]
    var green: [Double]
    var confidence: [Double]
    var colourTolerance: [Double]? = nil
}

struct SpatialField: Sendable, Codable {
    var surface: SurfaceLighting.Map? = nil
    var columns = 9
    var rows = 6
    var stops = [Double](repeating: 0, count: 54)
    var offsets = [Double](repeating: 0, count: 54)
    var exposureStops = [Double](repeating: 0, count: 54)
    var patchTone: SpatialPatchTone? = nil
    var brightnessEV: Double? = nil
    var validationStops: [Double]? = nil
    var sampleColumns = 24
    var sampleRows = 14
    var confidence = [Double](repeating: 0, count: 336)
    var motion = [Double](repeating: 1, count: 336)
    var requested = [Double](repeating: 0, count: 336)
    var applied = [Double](repeating: 0, count: 336)
    var before = [Double](repeating: 0, count: 336)
    var reference = [Double](repeating: 0, count: 336)
    var alignments: [SpatialAlignment] = []
    var cameraMotion: Bool? = nil
    var sharedExposureEV: Double? = nil
    var fallback: String? = "Spatial correction disabled"
    var peak: Double { surface?.channelEV.map { abs(Double($0)) }.max() ?? stops.map(abs).max() ?? 0 }

    func value(x: Double, y: Double) -> Double {
        Self.basis(x: x, y: y, columns: columns, rows: rows).reduce(0) { $0 + stops[$1.0] * $1.1 }
    }
    func offset(x: Double, y: Double) -> Double {
        Self.basis(x: x, y: y, columns: columns, rows: rows).reduce(0) { $0 + offsets[$1.0] * $1.1 }
    }
    static func basis(x: Double, y: Double, columns: Int, rows: Int) -> [(Int, Double)] {
        let px = max(0, min(Double(columns - 1), x * Double(columns - 1)))
        let py = max(0, min(Double(rows - 1), y * Double(rows - 1)))
        let ix = min(columns - 2, Int(px)), iy = min(rows - 2, Int(py))
        let fx = px - Double(ix), fy = py - Double(iy)
        return [(iy * columns + ix, (1-fx)*(1-fy)), (iy * columns + ix+1, fx*(1-fy)),
                ((iy+1) * columns + ix, (1-fx)*fy), ((iy+1) * columns + ix+1, fx*fy)]
    }
}

/// Streaming surface tracks keep the working image set to two thumbnails.
/// The field stores only gains and source guidance, never reference pixels.
enum SurfaceLighting {
    struct Map: Sendable, Codable {
        let width: Int
        let height: Int
        let channelEV: [Float]
        let guide: [Float]
        var rowModel: Bool? = nil
        /// Experimental neutral tone slope around 0.18 linear luminance.
        /// Nil preserves the original exposure-only renderer.
        var toneEV: [Float]? = nil
    }

    static var enabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_PIPELINE"] != "0" }
    static var tracksEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_TRACKING"] != "0" }
    static var colourEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_COLOUR"] != "0" }
    static var cameraGuidanceEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_CAMERA"] != "0" }
    static var sharedAnchorEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_ANCHOR"] != "0" }
    static var rowsEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_ROWS"] != "0" }
    static var refinementEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_REFINEMENT"] != "0" }
    static var crossMaterialLightingEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_CROSS_MATERIAL_LIGHT"] == "1" }
    static var shortTrackGraphEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_SHORT_TRACK_GRAPH"] == "1" }
    static var shortTrackJoiningEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_SHORT_TRACK_JOIN"] == "1" }
    /// Validate a shared gain on corresponding surfaces, never fixed screen
    /// positions. Genuine large source lighting steps cannot activate this guard.
    static func cameraValidationResidual(_ a: SpatialThumbnail,_ b: SpatialThumbnail,
                                         renderedA: SpatialThumbnail,renderedB: SpatialThumbnail) -> Double? {
        guard let model = SurfaceMotion.estimate(SurfaceMotion.coarse(a),SurfaceMotion.coarse(b)) else { return nil }
        func light(_ image: SpatialThumbnail,_ x: Double,_ y: Double) -> Double {
            let ix = Int(x),iy = Int(y),fx = x-Double(ix),fy = y-Double(iy)
            var sum = 0.0
            for dy in -6...6 { for dx in -6...6 { for c in 0..<3 {
                let xx = ix+dx,yy = iy+dy,right = min(image.width-1,xx+1),bottom = min(image.height-1,yy+1)
                let top = Double(image.rgb[(yy*image.width+xx)*3+c])*(1-fx)+Double(image.rgb[(yy*image.width+right)*3+c])*fx
                let low = Double(image.rgb[(bottom*image.width+xx)*3+c])*(1-fx)+Double(image.rgb[(bottom*image.width+right)*3+c])*fx
                sum += [0.2126,0.7152,0.0722][c]*max(0,top*(1-fy)+low*fy)/169
            } } }
            return max(0.000001,sum)
        }
        var observations: [(x: Int,y: Int,source: Double,residual: Double)] = []
        for y in stride(from: 6,to: a.height-6,by: 8) { for x in stride(from: 6,to: a.width-6,by: 8) {
            let q = model.point(Double(x),Double(y))
            guard let first = SurfaceTracking.descriptor(a,x: x,y: y,half: 6),
                  let second = SurfaceTracking.descriptor(b,x: q.0,y: q.1,half: 6),first.energy > 0.03,second.energy > 0.03 else { continue }
            let correlation = zip(first.texture,second.texture).reduce(0.0) { $0+$1.0*$1.1 }/(Double(first.texture.count)*first.energy*second.energy)
            guard correlation > 0.95 else { continue }
            let source = log2(light(b,q.0,q.1)/light(a,Double(x),Double(y)))
            let rendered = log2(light(renderedB,q.0,q.1)/light(renderedA,Double(x),Double(y)))
            observations.append((x,y,source,rendered-source))
        } }
        guard observations.count >= 12,
              observations.map(\.x).max()!-observations.map(\.x).min()! >= a.width/2,
              observations.map(\.y).max()!-observations.map(\.y).min()! >= a.height/2,
              ExposureMath.median(observations.map { abs($0.source) }) < 0.05 else { return nil }
        let residual = ExposureMath.median(observations.map(\.residual))
        guard observations.filter({ abs($0.residual-residual) < 0.05 }).count*5 >= observations.count*3 else { return nil }
        return residual
    }
    static var jointLightingEnabled: Bool { ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_JOINT"] != "0" }

    /// Reconcile fragmented histories through overlapping measurements of the
    /// same illumination. Appearance only limits the candidates; agreement of
    /// actual RGB changes is required before any temporal baseline is shared.
    /// Independent lights retain separate histories. Clean, low-energy motion
    /// supplies no evidence for this coupling and keeps its existing targets.
    /// Solve relative material reflectance from overlapping illumination
    /// observations. One gauge constraint fixes the otherwise arbitrary origin.
    private static func graphOffsets(count: Int,edges: [(Int,Int,[Double],Double)]) -> [[Double]]? {
        guard count >= 3,!edges.isEmpty else { return nil }
        var diagonal = [Double](repeating: 0,count: count)
        for (a,b,_,weight) in edges { diagonal[a] += weight;diagonal[b] += weight }
        guard diagonal.allSatisfy({ $0 > 0 }) else { return nil }
        func multiply(_ vector: [Double]) -> [Double] {
            var result = [Double](repeating: 0,count: count)
            result[0] = vector[0]
            for (a,b,_,weight) in edges {
                let difference = weight*(vector[a]-vector[b])
                result[a] += difference;result[b] -= difference
            }
            return result
        }
        func dot(_ a: [Double],_ b: [Double]) -> Double { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }
        var offsets = Array(repeating: [Double](repeating: 0,count: 3),count: count)
        for channel in 0..<3 {
            var rhs = [Double](repeating: 0,count: count)
            for (a,b,delta,weight) in edges { rhs[a] -= weight*delta[channel];rhs[b] += weight*delta[channel] }
            var solution = [Double](repeating: 0,count: count),residual = rhs,direction = rhs
            var error = dot(residual,residual)
            let tolerance = max(1e-18,error*1e-16)
            for _ in 0..<max(16,count*3) {
                if error <= tolerance { break }
                let product = multiply(direction), denominator = dot(direction,product)
                guard denominator > 1e-20 else { return nil }
                let step = error/denominator
                for i in 0..<count { solution[i] += step*direction[i];residual[i] -= step*product[i] }
                let next = dot(residual,residual),ratio = next/error
                for i in 0..<count { direction[i] = residual[i]+ratio*direction[i] }
                error = next
            }
            guard error <= tolerance*100,solution.allSatisfy(\.isFinite) else { return nil }
            for i in 0..<count { offsets[i][channel] = solution[i] }
        }
        return offsets
    }

    static func jointLighting(_ rawTracks: [[SurfaceTracking.Observation]],times: [Double],radius: Double,
                              mode: NormalisationMode,strength: Double,global: [Double],
                              shortTracks: Bool = shortTrackJoiningEnabled,shortGraph: Bool = shortTrackGraphEnabled,
                              crossMaterials: Bool = crossMaterialLightingEnabled,
                              contrastPhotometry: Bool = SurfaceTracking.contrastPhotometryEnabled,
                              confidenceTargets: Bool = ProcessInfo.processInfo.environment["FRANKLUMA_CONFIDENCE_TARGETS"] == "1") -> [Int: [SurfaceTracking.LightingEstimate]] {
        let tracks = contrastPhotometry ? rawTracks.map(SurfaceTracking.contrastHistory) : rawTracks
        func supported(_ point: SurfaceTracking.Observation) -> Bool {
            !confidenceTargets || (point.confidence.isFinite && point.confidence > 0)
        }
        guard jointLightingEnabled,strength > 0 else { return [:] }
        let eligible = tracks.indices.filter { index in
            let track = tracks[index]
            // Near-clipped channels do not retain multiplicative lighting:
            // correlated plateaus cannot establish a joint exposure history.
            return track.count >= (shortGraph ? 4 : 8) && track.reduce(0) { $0+$1.confidence }/Double(track.count) >= 0.65
                && track.filter(supported).allSatisfy { ($0.sourcePeakLevel ?? $0.channelLevels.max() ?? 0) < log2(0.8) }
        }
        func colourBucket(_ track: [SurfaceTracking.Observation]) -> Int {
            let colour = (0..<3).map { c in pow(2,ExposureMath.median(track.filter(supported).map(\.channelLevels).map { $0[c] })) }
            let total = colour.reduce(0,+)
            return Int(colour[0]/total*6)*7+Int(colour[1]/total*6)
        }
        var extent = 96
        if shortGraph && crossMaterials {
            for track in tracks { for point in track { extent = max(extent,point.x+1) } }
        }
        let cellWidth = max(32,extent/3)
        func candidateBucket(_ track: [SurfaceTracking.Observation]) -> Int {
            if shortGraph && crossMaterials {
                return Int(ExposureMath.median(track.map { Double($0.x) }))/cellWidth
            }
            return colourBucket(track)
        }
        let buckets = Dictionary(grouping: eligible) { candidateBucket(tracks[$0]) }
        let short = (shortTracks || shortGraph) ? tracks.indices.filter { index in
            let track = tracks[index]
            return (4..<8).contains(track.count) && track.reduce(0) { $0+$1.confidence }/Double(track.count) >= 0.75
                && track.filter(supported).allSatisfy { ($0.sourcePeakLevel ?? $0.channelLevels.max() ?? 0) < log2(0.8) }
        } : []
        let shortBuckets = Dictionary(grouping: short) { candidateBucket(tracks[$0]) }
        var shortProposals: [Int: [[SurfaceTracking.LightingEstimate]]] = [:]
        var output: [Int: [SurfaceTracking.LightingEstimate]] = shortGraph ? jointLighting(tracks,times: times,
            radius: radius,mode: mode,strength: strength,global: global,shortTracks: false,shortGraph: false,contrastPhotometry: contrastPhotometry,confidenceTargets: confidenceTargets) : [:]
        for bucket in buckets.keys.sorted() {
            if Task.isCancelled { return output }
            let members = buckets[bucket]!.sorted { tracks[$0].count == tracks[$1].count ? $0 < $1 : tracks[$0].count > tracks[$1].count }
            let cohort: [Int]
            if shortGraph && crossMaterials {
                // Candidate colour limits no longer define the light itself.
                // Balance materials so a large background cannot occupy every
                // fitting slot before smaller moving surfaces are considered.
                let pools = Dictionary(grouping: members) { colourBucket(tracks[$0]) }
                let colours = pools.keys.sorted()
                var balanced: [Int] = [],depth = 0
                while balanced.count < 128 {
                    var added = false
                    for colour in colours where balanced.count < 128 {
                        let pool = pools[colour]!
                        if depth < pool.count { balanced.append(pool[depth]);added = true }
                    }
                    if !added { break };depth += 1
                }
                cohort = balanced
            } else if shortGraph, members.count > 64 {
                let remainder = members.dropFirst(64).sorted { tracks[$0][0].frame < tracks[$1][0].frame }
                let extra = (0..<min(64,remainder.count)).map { Array(remainder)[$0*remainder.count/min(64,remainder.count)] }
                cohort = Array(members.prefix(64))+extra
            } else { cohort = Array(members.prefix(64)) }
            let selected = Set(cohort)
            let lookups = cohort.map { Dictionary(uniqueKeysWithValues: tracks[$0].map { ($0.frame,$0) }) }
            var parent = Array(cohort.indices)
            func root(_ index: Int) -> Int { var value = index;while parent[value] != value { value = parent[value] };return value }
            func agrees(_ a: [Int: SurfaceTracking.Observation],_ b: [Int: SurfaceTracking.Observation],short: Bool = false) -> Bool {
                let shared = a.keys.filter { frame in b[frame].map { supported(a[frame]!) && supported($0) } ?? false }.sorted()
                guard shared.count >= (short ? 4 : 8) else { return false }
                let adjacent = zip(shared,shared.dropFirst()).filter { $1 == $0+1 }
                guard adjacent.count >= (short ? 3 : 6) else { return false }
                let activeEnergy = adjacent.reduce(0.0) { sum,pair in
                    sum+(0..<3).reduce(0.0) { $0+pow(a[pair.1]!.channelLevels[$1]-a[pair.0]!.channelLevels[$1],2) }
                }/Double(adjacent.count*3)
                guard activeEnergy > 0.0004 else { return false }
                return (0..<3).allSatisfy { c in
                    let pairs = adjacent.map { before,after in
                        (a[after]!.channelLevels[c]-a[before]!.channelLevels[c],b[after]!.channelLevels[c]-b[before]!.channelLevels[c])
                    }
                    guard pairs.count >= (short ? 3 : 6) else { return false }
                    let energy = pairs.reduce(0) { $0+$1.0*$1.0 }
                    guard energy/Double(pairs.count) > 0.0004 else {
                        return pairs.reduce(0) { $0+$1.1*$1.1 }/Double(pairs.count) < 0.0004
                    }
                    let slope = pairs.reduce(0) { $0+$1.0*$1.1 }/energy
                    let error = pairs.reduce(0) { $0+abs($1.0-$1.1) }/Double(pairs.count)
                    return (0.85...1.15).contains(slope) && error < 0.025
                }
            }
            var edges: [(Int,Int)] = []
            for a in cohort.indices { for b in cohort.indices where b > a {
                let first = tracks[cohort[a]],second = tracks[cohort[b]]
                let brief = shortGraph && min(first.count,second.count) < 8
                guard min(first.last!.frame,second.last!.frame)-max(first.first!.frame,second.first!.frame) >= (brief ? 3 : 7),
                      agrees(lookups[a],lookups[b],short: brief) else { continue }
                edges.append((a,b))
            } }
            var supportedTracks = Set(cohort.indices.filter { tracks[cohort[$0]].count >= 8 })
            if shortGraph {
                for index in cohort.indices where tracks[cohort[index]].count < 8 {
                    let track = tracks[cohort[index]]
                    let middle = track[track.count/2].frame
                    let neighbours = edges.compactMap { $0.0 == index ? $0.1 : $0.1 == index ? $0.0 : nil }
                    let cells = Set(neighbours.compactMap { neighbour -> String? in
                        guard let point = lookups[neighbour][middle] else { return nil }
                        return "\(point.x/4):\(point.y/4)"
                    })
                    let own = track[track.count/2]
                    if cells.subtracting(["\(own.x/4):\(own.y/4)"]).count >= 2 { supportedTracks.insert(index) }
                }
            }
            for (a,b) in edges where supportedTracks.contains(a) && supportedTracks.contains(b) {
                let ra = root(a),rb = root(b);parent[rb] = ra
            }
            let groups = Dictionary(grouping: cohort.indices,by: root)
            for key in groups.keys.sorted() {
                let component = groups[key]!
                guard component.count >= 3 else { continue }
                if shortGraph,component.contains(where: { tracks[cohort[$0]].count < 8 }) {
                    let first = component.map { tracks[cohort[$0]].first!.frame }.min()!
                    let last = component.map { tracks[cohort[$0]].last!.frame }.max()!
                    // A collection of brief glimpses must actually establish
                    // a longer baseline, not merely repeat the same brief view.
                    guard times[last]-times[first] > 4*max(0.05,radius) else { continue }
                }
                var indices = component.map { cohort[$0] }
                // Additional fragments can use the established component only
                // after passing the same independent overlap agreement check.
                for index in members where !shortGraph && !selected.contains(index) {
                    let lookup = Dictionary(uniqueKeysWithValues: tracks[index].map { ($0.frame,$0) })
                    if component.contains(where: { agrees(lookups[$0],lookup) }) { indices.append(index) }
                }
                let frames = Array(Set(indices.flatMap { tracks[$0].map(\.frame) })).sorted()
                var offsets = indices.map { index in (0..<3).map { c in ExposureMath.median(tracks[index].filter(supported).map { $0.channelLevels[c] }) } }
                if shortGraph {
                    let views = indices.map { Dictionary(uniqueKeysWithValues: tracks[$0].map { ($0.frame,$0) }) }
                    var constraints: [(Int,Int,[Double],Double)] = []
                    for a in indices.indices { for b in indices.indices where b > a {
                        let brief = min(tracks[indices[a]].count,tracks[indices[b]].count) < 8
                        guard agrees(views[a],views[b],short: brief) else { continue }
                        let shared = views[a].keys.filter { frame in views[b][frame].map { supported(views[a][frame]!) && supported($0) } ?? false }
                        let delta = (0..<3).map { c in ExposureMath.median(shared.map { views[b][$0]!.channelLevels[c]-views[a][$0]!.channelLevels[c] }) }
                        let errors = shared.flatMap { frame in (0..<3).map { abs(views[b][frame]!.channelLevels[$0]-views[a][frame]!.channelLevels[$0]-delta[$0]) } }
                        guard ExposureMath.median(errors) < 0.015,(errors.max() ?? 1) < 0.05 else { continue }
                        constraints.append((a,b,delta,Double(shared.count)))
                    } }
                    guard let fitted = graphOffsets(count: indices.count,edges: constraints) else { continue }
                    offsets = fitted
                }
                var latent = [Int: [Double]]()
                let observations = Dictionary(grouping: indices.enumerated().flatMap { index,track in tracks[track].map { (index,$0) } },by: { $0.1.frame })
                for _ in 0..<(shortGraph ? 1 : 6) {
                    for frame in frames {
                        latent[frame] = (0..<3).map { c in ExposureMath.median(observations[frame]!.filter { supported($0.1) }.map { $0.1.channelLevels[c]-offsets[$0.0][c] }) }
                    }
                    if !shortGraph { for (k,index) in indices.enumerated() {
                        offsets[k] = (0..<3).map { c in ExposureMath.median(tracks[index].filter(supported).map { $0.channelLevels[c]-latent[$0.frame]![c] }) }
                    } }
                }
                let targets = (0..<3).map { c in
                    let samples = frames.map { ExposureSample(time: times[$0],level: latent[$0]![c],segment: 0) }
                    if confidenceTargets {
                        let weights = frames.map { frame in observations[frame]!.contains { supported($0.1) } ? 1.0 : 0.0 }
                        let levels = samples.map(\.level)
                        let values = mode == .steady ? Array(repeating: ExposureMath.weightedMedian(levels,weights: weights),count: levels.count)
                            : ExposureMath.smoothTargets(times: samples.map(\.time),levels: levels,radius: radius,reliability: weights)
                        return Dictionary(uniqueKeysWithValues: zip(frames,values))
                    }
                    let correction = ExposureMath.curve(samples: samples,radius: radius,strength: 1,mode: mode)
                    return Dictionary(uniqueKeysWithValues: zip(frames,zip(samples.map(\.level),correction.stops).map(+)))
                }
                // Short observations never fit or modify the established
                // history. They may use it only after agreement with three
                // spatially independent longer observations of the illumination.
                for index in shortBuckets[bucket] ?? [] where !indices.contains(index) {
                    let track = tracks[index]
                    guard track.allSatisfy({ latent[$0.frame] != nil }) else { continue }
                    let lookup = Dictionary(uniqueKeysWithValues: track.map { ($0.frame,$0) })
                    let donors = component.filter { agrees(lookups[$0],lookup,short: true) }
                    let cells = Set(donors.compactMap { donor -> String? in
                        guard let point = track.first.flatMap({ lookups[donor][$0.frame] }) else { return nil }
                        return "\(point.x/4):\(point.y/4)"
                    })
                    guard cells.count >= 3 else { continue }
                    let offset = (0..<3).map { c in ExposureMath.median(track.filter(supported).map { $0.channelLevels[c]-latent[$0.frame]![c] }) }
                    let errors = track.filter(supported).flatMap { point in (0..<3).map { abs(point.channelLevels[$0]-offset[$0]-latent[point.frame]![$0]) } }
                    guard errors.max()! < 0.025,ExposureMath.median(errors) < 0.0125 else { continue }
                    let independent = SurfaceTracking.lighting(track,times: times,radius: radius,mode: mode,strength: strength,global: global,confidenceTargets: confidenceTargets)
                    guard independent.count == track.count else { continue }
                    let proposal = zip(track,independent).map { point,estimate -> SurfaceTracking.LightingEstimate in
                        if estimate.usesSharedExposure { return estimate }
                        var result = estimate
                        result = .init(frame: point.frame,x: point.x,y: point.y,
                            channelEV: (0..<3).map { c in max(-2,min(2,targets[c][point.frame]!+offset[c]-point.channelLevels[c]))*strength },
                            confidence: estimate.confidence,protectsFromGlobal: estimate.protectsFromGlobal,
                            usesContrastPhotometry: estimate.usesContrastPhotometry,offsetX: estimate.offsetX,offsetY: estimate.offsetY)
                        return result
                    }
                    shortProposals[index,default: []].append(proposal)
                }
                for (k,index) in indices.enumerated() {
                    let track = tracks[index]
                    let errors = track.filter(supported).flatMap { point in (0..<3).map { abs(point.channelLevels[$0]-offsets[k][$0]-latent[point.frame]![$0]) } }
                    guard ExposureMath.median(errors) < 0.025 else { continue }
                    let independent = SurfaceTracking.lighting(track,times: times,radius: radius,mode: mode,strength: strength,global: global,confidenceTargets: confidenceTargets)
                    guard independent.count == track.count else { continue }
                    output[index] = zip(track,independent).map { point,estimate in
                        // A validated scene-wide lighting history is already
                        // the strongest target. Joint fragments may fill a
                        // missing local baseline, never replace that evidence.
                        if estimate.usesSharedExposure { return estimate }
                        var result = estimate
                        let gains = (0..<3).map { c in max(-2,min(2,targets[c][point.frame]!+offsets[k][c]-point.channelLevels[c]))*strength }
                        result = .init(frame: estimate.frame,x: estimate.x,y: estimate.y,channelEV: gains,confidence: estimate.confidence,
                            protectsFromGlobal: estimate.protectsFromGlobal,usesContrastPhotometry: estimate.usesContrastPhotometry,offsetX: estimate.offsetX,offsetY: estimate.offsetY)
                        return result
                    }
                }
            }
        }
        // Multiple compatible-looking groups leave the illumination identity
        // ambiguous. Keep the independent estimate rather than picking one.
        for (index,proposals) in shortProposals where proposals.count == 1 { output[index] = proposals[0] }
        return output
    }

    /// Represent shared illumination in the global curve and deviations in
    /// local gains. This keeps Spatial continuous down to its global-only end
    /// point and makes the exposure graph describe the actual shared gain.
    static func separatedCurve(times: [Double],global: [Double],fields: [SpatialField],spatialStrength: Double) -> ExposureCurve {
        guard fields.count == global.count,fields.allSatisfy({ $0.surface != nil && $0.sharedExposureEV != nil }) else {
            return ExposureCurve(times: times,stops: global,spatial: fields)
        }
        var result = fields
        let shared = fields.map { $0.sharedExposureEV! }
        for i in result.indices {
            let map = result[i].surface!
            let gains = spatialStrength == 0 ? Array(repeating: Float(0),count: map.channelEV.count) : map.channelEV.map { Float(Double($0)+global[i]-shared[i]) }
            result[i].surface = Map(width: map.width,height: map.height,channelEV: gains,guide: map.guide,rowModel: map.rowModel)
            result[i].applied = result[i].applied.map { spatialStrength == 0 ? 0 : $0+global[i]-shared[i] }
            result[i].requested = result[i].applied
        }
        return ExposureCurve(times: times,stops: shared,spatial: result)
    }

    /// Refine predicted rendered pixels on moving surfaces as well as static
    /// backgrounds. A fixed subset of spatial anchors never fits the update:
    /// it must improve independently before the bounded update is accepted.
    /// Only gains change; every pass still renders the original source pixels.
    static func refined(_ map: Map, points: [SurfaceTracking.LightingEstimate], global: Double, shared: Double,
                        strength: Double, spatialStrength: Double, colourStrength: Double = 1) -> Map {
        guard refinementEnabled, map.rowModel != true, strength > 0, spatialStrength > 0 else { return map }
        struct Anchor {
            let x: Int
            let y: Int
            let rgb: [Double]
            let target: [Double]
            let confidence: Double
            let group: String
            let window: [(Double,Double,[Double])]
            let usesContrastPhotometry: Bool
        }
        let cells = Dictionary(grouping: points.filter { $0.confidence > 0.65 }) { "\($0.x/4):\($0.y/4)" }
        let anchors: [Anchor] = cells.values.compactMap { values -> Anchor? in
            guard let point = values.max(by: { $0.confidence < $1.confidence }),
                  point.x >= 0,point.y >= 0,point.x < map.width,point.y < map.height else { return nil }
            let k = (point.y*map.width+point.x)*3
            let rgb = (0..<3).map { Double(map.guide[k+$0]) }
            guard rgb.min()! > 0.015,rgb.max()! < 0.8 else { return nil }
            let target = point.channelEV.map { shared+($0-shared)*spatialStrength }
            let total = rgb.reduce(0,+)
            // Validate material groups separately, so numerous background
            // anchors cannot conceal a regression on a smaller foreground.
            let material = Int(rgb[0]/total*5)*6+Int(rgb[1]/total*5)
            // Equal colours can belong to independently illuminated surfaces.
            // Require validation for the requested lighting change as well.
            let lighting = target.map { Int(($0/max(0.000001,strength)/0.15).rounded()) }
            let group = "\(material):\(lighting[0]):\(lighting[1]):\(lighting[2])"
            var window: [(Double,Double,[Double])] = []
            for dy in -2...2 { for dx in -2...2 {
                let xx = Double(point.x+dx)+point.offsetX,yy = Double(point.y+dy)+point.offsetY
                guard xx >= 0,yy >= 0,xx < Double(map.width-1),yy < Double(map.height-1) else { continue }
                let ix = Int(xx),iy = Int(yy),fx = xx-Double(ix),fy = yy-Double(iy)
                let p = (iy*map.width+ix)*3
                var values = [Double](repeating: 0,count: 3)
                for c in 0..<3 {
                    let top = Double(map.guide[p+c])*(1-fx)+Double(map.guide[p+3+c])*fx
                    let bottom = Double(map.guide[p+map.width*3+c])*(1-fx)+Double(map.guide[p+map.width*3+3+c])*fx
                    values[c] = top*(1-fy)+bottom*fy
                }
                window.append(((xx+0.5)/Double(map.width),(yy+0.5)/Double(map.height),values))
            } }
            guard window.count == 25 else { return nil }
            // Keep the support fixed from source pixels. A dark/clipped edge
            // cannot provide a trustworthy per-channel residual after gain.
            guard window.allSatisfy({ $0.2.min()! > 0.015 && $0.2.max()! < 0.8 }) else { return nil }
            return Anchor(x: point.x,y: point.y,rgb: rgb,target: target,confidence: point.confidence,group: group,window: window,usesContrastPhotometry: point.usesContrastPhotometry)
        }.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
        let validation = anchors.filter { ($0.x/4)%5 == 0 && ($0.y/4)%3 == 0 }
        // Five-pixel separation includes the possible fractional sampling
        // offset: fitting and validation must not share source pixels.
        let validationCounts = Dictionary(grouping: validation,by: { $0.group }).mapValues(\.count)
        let training = anchors.filter { anchor in
            (validationCounts[anchor.group] ?? 0) >= 2 && !validation.contains { abs($0.x-anchor.x) <= 5 && abs($0.y-anchor.y) <= 5 }
        }
        guard validation.count >= 4,training.count >= 12 else { return map }
        func residual(_ anchor: Anchor,_ candidate: Map) -> [Double] {
            // Targets came from a tracked patch's mean log light. Validate that
            // same footprint, rather than comparing it with a single centre
            // pixel across a moving edge or an illumination gradient.
            if anchor.usesContrastPhotometry {
                var before = [Double](repeating: 0,count: 3),after = before
                for (x,y,rgb) in anchor.window {
                    let rendered = SpatialRenderer.surfaceRGB(rgb,x: x,y: y,map: candidate,global: global)
                    for c in 0..<3 {
                        before[c] += log2(max(0.003,rgb[c]))/25
                        after[c] += log2(max(0.003,rendered[c]))/25
                    }
                }
                guard let source = SurfaceTracking.colourContrast(before),let corrected = SurfaceTracking.colourContrast(after) else {
                    return [10,10,10] // Invalid photometric support must fail validation.
                }
                let rotation = sqrt(zip(source.direction,corrected.direction).reduce(0) { $0+pow($1.0-$1.1,2) })
                guard rotation < 0.025 else { return [10,10,10] }
                let error = anchor.target.reduce(0,+)/3-(corrected.level-source.level)
                return [error,error,error]
            }
            var gains = [Double](repeating: 0,count: 3)
            for (x,y,rgb) in anchor.window {
                let rendered = SpatialRenderer.surfaceRGB(rgb,x: x,y: y,map: candidate,global: global)
                for c in 0..<3 { gains[c] += log2(max(0.003,rendered[c])/max(0.003,rgb[c]))/25 }
            }
            return (0..<3).map { anchor.target[$0]-gains[$0] }
        }
        func losses(_ candidate: Map) -> [String: Double] {
            let renderedMap = Map(width: candidate.width,height: candidate.height,
                channelEV: colourAdjustedGains(candidate.channelEV,guide: candidate.guide,amount: colourStrength),
                guide: candidate.guide,rowModel: candidate.rowModel)
            let groups: [String: [Anchor]] = Dictionary(grouping: validation,by: { $0.group })
            return groups.mapValues { group in
                group.reduce(0) { sum,anchor in
                    let target = colourAdjustedGains(anchor.target.map { Float($0-global) },
                        guide: anchor.rgb.map(Float.init),amount: colourStrength).map { Double($0)+global }
                    let actualResidual = residual(anchor,renderedMap)
                    let error = (0..<3).map { actualResidual[$0]+target[$0]-anchor.target[$0] }
                    return sum+error.reduce(0) { $0+$1*$1 }*anchor.confidence
                }
                    / max(0.000001,group.reduce(0) { $0+$1.confidence }*3)
            }
        }
        var current = map
        let initialLoss = losses(current)
        guard initialLoss.values.reduce(0,+)/Double(max(1,initialLoss.count)) > pow(0.02*strength,2) else { return map }
        for _ in 0..<2 {
            if Task.isCancelled { return current }
            let errors = training.map { residual($0,current) }
            var gains = current.channelEV
            for y in 0..<map.height { for x in 0..<map.width {
                let k = (y*map.width+x)*3
                let rgb = (0..<3).map { Double(map.guide[k+$0]) }
                var sum = [Double](repeating: 0,count: 3),weight = 0.0,support = 0
                for (i,anchor) in training.enumerated() {
                    let distance = Double((x-anchor.x)*(x-anchor.x)+(y-anchor.y)*(y-anchor.y))
                    guard distance <= 100 else { continue }
                    var difference = 0.0
                    for c in 0..<3 { difference += pow(log2(max(0.003,rgb[c])/max(0.003,anchor.rgb[c])),2) }
                    let value = anchor.confidence*exp(-distance/20-difference/0.12)
                    guard value > 0.03 else { continue }
                    support += 1;weight += value
                    for c in 0..<3 { sum[c] += errors[i][c]*value }
                }
                guard support >= 2,weight > 0.15 else { continue }
                for c in 0..<3 {
                    let delta = max(-0.12*strength*spatialStrength,min(0.12*strength*spatialStrength,sum[c]/weight))
                    gains[k+c] += Float(delta)
                }
            } }
            let proposal = Map(width: map.width,height: map.height,channelEV: gains,guide: map.guide,rowModel: map.rowModel)
            let before = losses(current),after = losses(proposal)
            let totalBefore = before.values.reduce(0,+),totalAfter = after.values.reduce(0,+)
            guard totalAfter < totalBefore*0.98,
                  before.allSatisfy({ group,error in (after[group] ?? .infinity) <= error+pow(0.002*strength,2) }) else { break }
            current = proposal
        }
        return current
    }

    /// The scene meter can be dominated by one flashing light. A separately
    /// supported surface group which needs less correction establishes that
    /// this is local illumination, not an exposure change shared by everything.
    /// Use one vote per spatial cell so duplicate tracks cannot create evidence.
    static func sharedExposure(_ points: [SurfaceTracking.LightingEstimate], global: Double,
                               strength: Double) -> Double {
        guard strength > 0, abs(global) > 0.06*strength else { return global }
        guard ProcessInfo.processInfo.environment["FRANKLUMA_SURFACE_SHARED"] != "0" else { return global }
        let supported = points.filter { $0.confidence >= 0.4 }
        guard Set(supported.map { "\($0.x/4):\($0.y/4)" }).count >= 12 else { return global }
        let groups = Dictionary(grouping: supported.filter(\.protectsFromGlobal)) { "\($0.x/4):\($0.y/4)" }
        let values = groups.values.compactMap { group -> Double? in
            guard let point = group.max(by: { $0.confidence < $1.confidence }) else { return nil }
            return 0.2126*point.channelEV[0]+0.7152*point.channelEV[1]+0.0722*point.channelEV[2]
        }
        guard values.count >= 4 else { return global }
        let ordered = values.sorted { abs($0) < abs($1) }
        for candidate in ordered {
            guard abs(candidate) < abs(global)-0.06*strength else { break }
            let neighbours = values.filter { abs($0-candidate) <= 0.025*strength }
            guard neighbours.count >= max(4,values.count/12) else { continue }
            let shared = ExposureMath.median(neighbours)
            return global > 0 ? max(0,min(global,shared)) : min(0,max(global,shared))
        }
        return global
    }

    /// A row illumination model requires wide agreement and a coherent spatial
    /// signal. A horizontal local flash, global exposure change, or moving
    /// object's reflectance therefore cannot activate it on its own.
    static func rowIllumination(_ points: [SurfaceTracking.LightingEstimate], width: Int, height: Int, strength: Double = 1) -> [[Double]]? {
        guard strength > 0 else { return nil }
        let positions = Array(stride(from: 2,to: height-2,by: 4))
        var observed: [[Double]?] = []
        for y in positions {
            observed.append(nil)
            let candidates = points.filter { abs($0.y-y) <= 1 && $0.confidence > 0.3 && $0.x >= 0 && $0.x < width }
            // One independent vote per grid column. Repeated tracks and fixed
            // anchors at the same location cannot manufacture spatial support.
            let groups = Dictionary(grouping: candidates) { $0.x / 4 }
            let selected = groups.values.compactMap { $0.max { $0.confidence < $1.confidence } }
            guard selected.count >= 10,
                  let left = selected.map(\.x).min(), let right = selected.map(\.x).max(),
                  left < width/4, right >= width*3/4,
                  (0..<4).allSatisfy({ quarter in selected.filter { min(3,$0.x*4/max(1,width)) == quarter }.count >= 2 }) else { continue }
            let centre = (0..<3).map { c in ExposureMath.median(selected.map { $0.channelEV[c] }) }
            let errors = selected.map { p in (0..<3).map { abs(p.channelEV[$0]-centre[$0]) }.max()! }
            guard ExposureMath.median(errors) < 0.04*strength,
                  Double(errors.filter { $0 < 0.08*strength }.count)/Double(errors.count) > 0.75 else { continue }
            observed[observed.count-1] = centre
        }
        // Bridge an isolated unsupported row only when neighbouring rows
        // establish the same full-width illumination model. Never extrapolate
        // across missing edges or a broad region with no evidence.
        guard observed.count >= 4, observed.first! != nil, observed.last! != nil,
              observed.compactMap({ $0 }).count*4 >= observed.count*3 else { return nil }
        var nodes: [[Double]] = []
        for index in observed.indices {
            if let value = observed[index] { nodes.append(value); continue }
            guard index > 0,index+1 < observed.count,
                  let before = observed[index-1],let after = observed[index+1] else { return nil }
            nodes.append(zip(before,after).map { ($0+$1)/2 })
        }
        let light = nodes.map { $0.reduce(0,+)/3 }, mean = light.reduce(0,+)/Double(light.count)
        guard sqrt(light.reduce(0) { $0+pow($1-mean,2) }/Double(light.count)) > 0.08*strength else { return nil }
        return (0..<height).map { y in
            let coordinate = max(0,min(Double(nodes.count-1),Double(y-2)/4))
            let i = min(nodes.count-2,Int(coordinate)), t = coordinate-Double(i)
            return (0..<3).map { c in
                let a = nodes[max(0,i-1)][c], b = nodes[i][c], d = nodes[i+1][c], e = nodes[min(nodes.count-1,i+2)][c]
                let value = 0.5*((2*b)+(-a+d)*t+(2*a-5*b+4*d-e)*t*t+(-a+3*b-3*d+e)*t*t*t)
                return max(min(b,d)-0.02*strength,min(max(b,d)+0.02*strength,value))
            }
        }
    }

    /// Illumination varies over surfaces more smoothly than image texture.
    /// Regularise measurements in chromaticity space while leaving the source
    /// image untouched. Brightness edges alone must not isolate shadow-shaped
    /// gain islands. Coherent row illumination retains its dedicated model.
    static func regularizedGains(_ gains: [Float], guide: [Float], width: Int, height: Int,
                                 strength: Double = 1,
                                 preserveLightingBoundaries: Bool = ProcessInfo.processInfo.environment["FRANKLUMA_GAIN_BOUNDARIES"] == "1") -> [Float] {
        guard gains.count == width*height*3, guide.count == gains.count else { return gains }
        let levels = (0..<(width*height)).map { p in
            (0..<3).map { log2(max(0.003,Double(guide[p*3+$0]))) }
        }
        let light = levels.map { $0.reduce(0,+)/3 }
        let colours = levels.enumerated().map { p,channels in channels.map { $0-light[p] } }
        var current = gains
        for _ in 0..<2 {
            for horizontal in [true,false] {
                var next = current
                for y in 0..<height { for x in 0..<width {
                    let p = y*width+x
                    var sum = [Double](repeating: 0,count: 3), total = 0.0
                    for offset in -12...12 {
                        let xx = horizontal ? x+offset : x, yy = horizontal ? y : y+offset
                        guard xx >= 0,xx < width,yy >= 0,yy < height else { continue }
                        let q = yy*width+xx
                        let colour = zip(colours[p],colours[q]).reduce(0) { $0+pow($1.0-$1.1,2) }
                        // Large reflectance differences still separate neutral
                        // materials; modest shadow edges can share smooth gain.
                        // Similar reflectance does not imply shared lighting.
                        // Use the original field throughout the iterations so
                        // diffusion cannot gradually erase independent gains.
                        let gainDifference = preserveLightingBoundaries ? (0..<3).reduce(0.0) {
                            $0+pow(Double(gains[p*3+$1]-gains[q*3+$1]),2)/3
                        }/max(0.000000000001,strength*strength*0.04) : 0
                        let weight = exp(-Double(offset*offset)/72-colour/0.06-pow(light[p]-light[q],2)/0.25-gainDifference)
                        total += weight
                        for c in 0..<3 { sum[c] += Double(current[q*3+c])*weight }
                    }
                    for c in 0..<3 { next[p*3+c] = Float(sum[c]/max(0.000001,total)) }
                } }
                current = next
            }
        }
        return current
    }

    /// Interpolate colour in log gain while holding corrected linear luminance
    /// fixed. Turning colour down cannot silently turn exposure correction down.
    static func colourAdjustedGains(_ gains: [Float], guide: [Float], amount: Double) -> [Float] {
        guard gains.count == guide.count,gains.count.isMultiple(of: 3) else { return gains }
        let amount = max(0,min(1,amount))
        if amount == 1 { return gains }
        return stride(from: 0,to: gains.count,by: 3).flatMap { p -> [Float] in
            let weights = [0.2126,0.7152,0.0722]
            let light = (0..<3).reduce(0.0) { $0+weights[$1]*Double(guide[p+$1]) }
            let target = (0..<3).reduce(0.0) { $0+weights[$1]*Double(guide[p+$1])*pow(2,Double(gains[p+$1])) }
            let neutral = log2(max(0.000001,target)/max(0.000001,light))
            let mixed = (0..<3).map { neutral+(Double(gains[p+$0])-neutral)*amount }
            let measured = (0..<3).reduce(0.0) { $0+weights[$1]*Double(guide[p+$1])*pow(2,mixed[$1]) }
            let offset = log2(max(0.000001,target)/max(0.000001,measured))
            return mixed.map { Float($0+offset) }
        }
    }

    /// A camera-motion match must agree with the illumination change observed
    /// by other surfaces. Reverse geometry alone cannot reject a repeated mark
    /// or a newly revealed highlight. Uniform exposure/colour shifts remain valid.
    static func motionPhotometricConfidence(delta: [Double], common: [Double]) -> Double {
        guard delta.count == 3,common.count == 3 else { return 0 }
        let errors = zip(delta,common).map(-)
        let light = errors.reduce(0,+)/3
        let colour = errors.map { $0-light }.map(abs).max()!
        return exp(-pow(light/0.35,2)-pow(colour/0.12,2))
    }

    /// Only measurements supported at both ends can define shared illumination.
    static func supportedCommonDelta(_ measurements: [(delta: [Double], confidence: Double)]) -> [Double] {
        let valid = measurements.filter { $0.confidence.isFinite && $0.confidence > 0 && $0.delta.count == 3 && $0.delta.allSatisfy(\.isFinite) }
        return (0..<3).map { c in ExposureMath.median(valid.map { $0.delta[c] }) }
    }

    static func supportedIlluminationPower(_ estimates: [SurfaceTracking.LightingEstimate], global: [Double], strength: Double) -> Double {
        let valid = estimates.filter { $0.confidence.isFinite && $0.confidence > 0 && global.indices.contains($0.frame) && $0.channelEV.count == 3 && $0.channelEV.allSatisfy(\.isFinite) }
        guard !valid.isEmpty else { return 0 }
        return valid.reduce(0.0) { sum,point in
            sum+point.channelEV.reduce(0) { $0+pow(($1-global[point.frame])/max(0.000001,strength),2) }
        }/Double(valid.count*3)
    }

    static func supportedTrajectoryWeight(_ track: [SurfaceTracking.Observation]) -> Double {
        let count = track.filter { $0.confidence.isFinite && $0.confidence > 0 }.count
        return max(0,min(1,Double(count-4)/12))
    }

    /// Rank usable material donors before consensus; an unsupported closer
    /// surface must not displace supported observations of the same material.
    static func materialDonors(_ points: [SurfaceTracking.LightingEstimate], rgb: [Float], pixel: Int, channel: Int, width: Int, height: Int) -> [(ev: Double, confidence: Double)] {
        var best = 0.12, candidates: [(ev: Double, confidence: Double)] = []
        for point in points where point.confidence.isFinite && point.confidence > 0 {
            let centre = (point.y*width+point.x)*3
            let errors = (0..<3).map { c in log2(max(0.003,Double(rgb[pixel*3+c]))/max(0.003,Double(rgb[centre+c]))) }
            let common = errors.reduce(0,+)/3
            let error = errors.reduce(0) { $0+pow($1-common,2) } + 0.02*common*common
            let distance = Double((pixel%width-point.x)*(pixel%width-point.x)+(pixel/width-point.y)*(pixel/width-point.y))
            let score = error + distance/Double(width*width+height*height)*0.02
            if score < best-0.005 { best = score; candidates = [(point.channelEV[channel],point.confidence)] }
            else if score <= best+0.005 { candidates.append((point.channelEV[channel],point.confidence)) }
        }
        return candidates
    }

    /// Missing local support must not restore gains from weak distant tracks.
    static func materialConsensus(_ candidates: [(ev: Double, confidence: Double)], strength: Double = 1) -> (ev: Double, reliability: Double)? {
        let valid = candidates.filter { $0.ev.isFinite && $0.confidence.isFinite && $0.confidence > 0 }
        guard valid.count >= 2 else { return nil }
        let ordered = valid.sorted { $0.ev < $1.ev }
        let support = valid.reduce(0.0) { $0+min(1,$1.confidence) }
        var accumulated = 0.0
        let median = ordered.first { point in
            accumulated += min(1,point.confidence)
            return accumulated >= support/2
        }!.ev
        let disagreement = valid.reduce(0.0) { $0+min(1,$1.confidence)*abs($1.ev-median) }/support
        return (median,min(1,support/4)*exp(-pow(disagreement/max(0.000001,strength)/0.15,2)))
    }

    /// Validate local brightness against held source patches, without borrowing
    /// neighbouring image pixels or extrapolating over a different material.
    static func validatedGains(_ map: Map, residuals: [(Int, Double)], amount: Double) -> Map {
        guard amount > 0, map.width >= 24, map.height >= 14,
              map.channelEV.count == map.width*map.height*3, map.guide.count == map.channelEV.count else { return map }
        let w = map.width, h = map.height
        var errors = [Int: Double](), colours = [Int: [Double]]()
        for (patch,error) in residuals where (0..<336).contains(patch) && error.isFinite {
            let col = patch%24, row = patch/24
            var rgb = [Double](repeating: 0,count: 3), count = 0
            for y in row*h/14..<(row+1)*h/14 { for x in col*w/24..<(col+1)*w/24 {
                for c in 0..<3 { rgb[c] += Double(map.guide[(y*w+x)*3+c]) }
                count += 1
            } }
            colours[patch] = rgb.map { log2(max(0.003,$0/Double(count))) }
            errors[patch] = max(-0.2,min(0.2,error))
        }
        guard errors.count >= 18 else { return map }
        var gains = map.channelEV
        for y in 0..<h { for x in 0..<w {
            let col = min(23,x*24/w), row = min(13,y*14/h), pixel = (y*w+x)*3
            let colour = (0..<3).map { log2(max(0.003,Double(map.guide[pixel+$0]))) }
            var sum = 0.0, support = 0.0, independent = 0
            for r in max(0,row-1)...min(13,row+1) { for c in max(0,col-1)...min(23,col+1) {
                let patch = r*24+c
                guard let error = errors[patch], let guide = colours[patch] else { continue }
                let difference = zip(colour,guide).reduce(0.0) { $0+pow($1.0-$1.1,2) }
                let dx = Double(x)-(Double(c)+0.5)*Double(w)/24+0.5
                let dy = Double(y)-(Double(r)+0.5)*Double(h)/14+0.5
                let weight = exp(-(dx*dx+dy*dy)/24-difference/0.18)
                if weight > 0.1 { independent += 1 }
                sum += weight*error;support += weight
            } }
            guard independent >= 2, support > 0.000001 else { continue }
            let adjustment = sum/support*min(1,support/0.5)*max(0,min(1,amount))
            for c in 0..<3 { gains[pixel+c] += Float(adjustment) }
        } }
        return Map(width: w,height: h,channelEV: gains,guide: map.guide,rowModel: map.rowModel)
    }

    static func estimate(samples: [ExposureSample], global: [Double], radius: Double,
                         strength: Double, spatialStrength: Double = 1, colourStrength: Double = 1, mode: NormalisationMode) -> [SpatialField] {
        guard samples.count == global.count, let first = samples.first?.thumbnail,
              samples.allSatisfy({ $0.thumbnail?.width == first.width && $0.thumbnail?.height == first.height }) else { return [] }
        let confidenceTargets = ProcessInfo.processInfo.environment["FRANKLUMA_CONFIDENCE_TARGETS"] == "1"
        let w = first.width, h = first.height, spacing = 4
        var tracks: [[SurfaceTracking.Observation]] = []
        var active: [Int] = []
        var previous: SurfaceTracking.Prepared?
        var previousCoarse: SurfaceTracking.Prepared?
        // A zoom may temporarily lose its camera model as texture moves across
        // the coarse grid. Retain scene-level shape evidence through those gaps.
        var cameraModels: [SurfaceMotion.Model?] = []
        var sceneShapeMotion = false
        func changesShape(_ model: SurfaceMotion.Model?) -> Bool {
            model.map { max(abs($0.x[0]-1),abs($0.x[1]),abs($0.y[0]),abs($0.y[1]-1)) > 0.005 } ?? false
        }
        if SurfaceTracking.contrastTrackingEnabled && cameraGuidanceEnabled {
            cameraModels = Array(repeating: nil,count: samples.count)
            // Retain only the recent coarse descriptors, rather than a full
            // scene of prepared images. Longer baselines reveal slow geometry
            // changes which fall below adjacent-frame correspondence precision.
            var history = [SurfaceTracking.Prepared]()
            for i in samples.indices {
                history.append(SurfaceMotion.coarse(samples[i].thumbnail!))
                let last = history.count-1
                if i > 0,samples[i].segment == samples[i-1].segment {
                    cameraModels[i] = SurfaceMotion.estimate(history[last-1],history[last])
                    sceneShapeMotion = sceneShapeMotion || changesShape(cameraModels[i])
                }
                if !sceneShapeMotion,i.isMultiple(of: 4) {
                    for distance in [4,8] where last >= distance && samples[i].segment == samples[i-distance].segment {
                        if changesShape(SurfaceMotion.estimate(history[last-distance],history[last])) {
                            sceneShapeMotion = true
                            break
                        }
                    }
                }
                if history.count > 8 { history.removeFirst() }
            }
        }
        var cameraModelFound = false
        var links = [[SpatialAlignment]](repeating: [],count: samples.count)
        for i in samples.indices {
            if Task.isCancelled { return [] }
            let current = SurfaceTracking.Prepared(samples[i].thumbnail!)
            let currentCoarse = cameraModels.isEmpty ? SurfaceMotion.coarse(samples[i].thumbnail!) : nil
            let motion = cameraModels.indices.contains(i) ? cameraModels[i] : (cameraGuidanceEnabled ? previousCoarse.flatMap { prior in
                currentCoarse.flatMap { samples[i].segment == samples[max(0,i-1)].segment ? SurfaceMotion.estimate(prior,$0) : nil }
            } : nil)
            cameraModelFound = cameraModelFound || motion != nil
            // Contrast normalisation assumes the same local texture footprint.
            // Camera zoom/rotation changes that footprint even at a good centre
            // correspondence; retain raw texture matching under such motion.
            let shapeMotion = motion.map { max(abs($0.x[0]-1),abs($0.x[1]),abs($0.y[0]),abs($0.y[1]-1)) > 0.005 } ?? false
            let contrastMatching = SurfaceTracking.contrastTrackingEnabled && !shapeMotion && !sceneShapeMotion
            var next: [Int] = []
            var occupied = Set<Int>()
            var dx: [Double] = [], dy: [Double] = [], errors: [Double] = []
            var candidates: [(track: Int,match: SurfaceTracking.Match,levels: [Double],delta: [Double])] = []
            let flow = ProcessInfo.processInfo.environment["FRANKLUMA_VISION_FLOW"] == "1" && tracksEnabled && i > 0 && samples[i].segment == samples[i-1].segment
                ? (samples[i].thumbnail!.previousFlow ?? SurfaceMotion.opticalFlow(samples[i-1].thumbnail!,samples[i].thumbnail!)) : nil
            if tracksEnabled, let previous, i > 0, samples[i].segment == samples[i-1].segment {
                for track in active {
                    let point = tracks[track].last!
                    guard let match = SurfaceTracking.match(previous, current, x: point.x, y: point.y, radius: 6,motion: motion,flow: flow,
                        offsetX: point.offsetX,offsetY: point.offsetY,contrastInvariant: contrastMatching) else { continue }
                    guard let levels = current.lighting(match) else { continue }
                    candidates.append((track,match,levels,zip(levels,point.channelLevels).map(-)))
                    dx.append(Double(match.x-point.x)); dy.append(Double(match.y-point.y)); errors.append(match.error)
                }
            }
            if dx.count >= 12 {
                let x = Int(ExposureMath.median(dx).rounded()), y = Int(ExposureMath.median(dy).rounded())
                let error = ExposureMath.median(errors)
                links[i].append(.init(reference: i-1,dx: -x,dy: -y,error: error,accepted: true))
                links[i-1].append(.init(reference: i,dx: x,dy: y,error: error,accepted: true))
            }
            let movingCamera = dx.count >= 12 && (abs(ExposureMath.median(dx)) >= 0.5 || abs(ExposureMath.median(dy)) >= 0.5)
            let common = confidenceTargets ? supportedCommonDelta(candidates.map {
                ($0.delta,$0.match.photometricConfidence*tracks[$0.track].last!.confidence)
            }) : (0..<3).map { c in ExposureMath.median(candidates.map { $0.delta[c] }) }
            for candidate in candidates {
                var support = movingCamera ? motionPhotometricConfidence(delta: candidate.delta,common: common) : 1
                if movingCamera,ProcessInfo.processInfo.environment["FRANKLUMA_LOCAL_LIGHT_TRACKS"] == "1",let previous {
                    support = max(support,SurfaceTracking.localMeasurementIdentity(previous,current,
                        point: tracks[candidate.track].last!,match: candidate.match))
                }
                guard support > 0.15 else { continue }
                let match = candidate.match
                tracks[candidate.track].append(.init(frame: i,x: match.x,y: match.y,
                    channelLevels: candidate.levels,confidence: match.confidence*support*match.photometricConfidence,neutralTextureConfidence: current.neutralSupport(match),offsetX: match.offsetX,offsetY: match.offsetY))
                next.append(candidate.track)
                occupied.insert((match.y/spacing)*(w/spacing+1)+match.x/spacing)
            }
            for y in stride(from: 2, to: h-2, by: spacing) { for x in stride(from: 2, to: w-2, by: spacing) {
                let cell = (y/spacing)*(w/spacing+1)+x/spacing
                guard !occupied.contains(cell) else { continue }
                guard let levels = current.lighting(x: x,y: y) else { continue }
                next.append(tracks.count)
                tracks.append([.init(frame: i, x: x, y: y, channelLevels: levels, confidence: 1,neutralTextureConfidence: current.neutralSupport(x: x,y: y))])
            } }
            active = next; previous = current;previousCoarse = currentCoarse
        }
        let cameraMoves = cameraModelFound || links.enumerated().contains { i, references in
            references.contains { $0.reference == i-1 && ($0.dx != 0 || $0.dy != 0) }
        }
        var points = [[SurfaceTracking.LightingEstimate]](repeating: [], count: samples.count)
        if SurfaceTracking.contrastPhotometryEnabled { tracks = tracks.map(SurfaceTracking.contrastHistory) }
        let joint = jointLighting(tracks,times: samples.map(\.time),radius: radius,mode: mode,strength: strength,global: global)
        for (index,track) in tracks.enumerated() {
            if Task.isCancelled { return [] }
            let estimates = joint[index] ?? SurfaceTracking.lighting(track, times: samples.map(\.time), radius: radius, mode: mode, strength: strength,global: sharedAnchorEnabled ? global : [])
            let moves = cameraMoves || zip(track,track.dropFirst()).contains { $0.x != $1.x || $0.y != $1.y }
            var illuminationSupport = 1.0
            if moves, !estimates.isEmpty {
                // Integer thumbnail correspondence has a small photometric
                // noise floor at moving edges. Shrink weak local departures
                // from shared exposure continuously rather than manufacturing
                // flicker from that noise. Normalize before Strength scaling.
                let power = confidenceTargets ? supportedIlluminationPower(estimates,global: global,strength: strength) : estimates.reduce(0.0) { sum,point in
                    sum+point.channelEV.reduce(0) { $0+pow(($1-global[point.frame])/max(0.000001,strength),2) }
                }/Double(estimates.count*3)
                illuminationSupport = power/(power+0.02*0.02)
            }
            for point in estimates {
                // Partial camera trajectories have a weak temporal baseline.
                // Fade their contribution in rather than switching a full gain
                // on as soon as a newly revealed surface has four observations.
                let support = cameraMoves ? (confidenceTargets ? supportedTrajectoryWeight(track) : max(0,min(1,Double(track.count-4)/12))) : 1
                if support > 0 {
                    points[point.frame].append(.init(frame: point.frame,x: point.x,y: point.y,
                        channelEV: point.channelEV.map { global[point.frame]+($0-global[point.frame])*illuminationSupport },
                        confidence: point.confidence*support,protectsFromGlobal: point.protectsFromGlobal,
                        usesContrastPhotometry: point.usesContrastPhotometry,offsetX: point.offsetX,offsetY: point.offsetY))
                }
            }
        }
        // Stationary surfaces supplement interrupted tracks only when a wider
        // lighting-invariant texture establishes identity. Chromaticity alone
        // cannot distinguish a neutral moving subject from neutral background.
        if !cameraMoves {
            for y in stride(from: 2, to: h-2, by: spacing) { for x in stride(from: 2, to: w-2, by: spacing) {
                if Task.isCancelled { return [] }
                var observations: [SurfaceTracking.Observation] = []
                var colours: [[Double]] = []
                var descriptors: [SurfaceTracking.Descriptor?] = []
                for i in samples.indices {
                    descriptors.append(SurfaceTracking.descriptor(samples[i].thumbnail!,x: x,y: y,half: 6))
                    let rgb = samples[i].thumbnail!.rgb
                    var levels = [Double](repeating: 0, count: 3)
                    for dy in -2...2 { for dx in -2...2 { for c in 0..<3 {
                        levels[c] += log2(max(0.003,Double(rgb[((y+dy)*w+x+dx)*3+c]))) / 25
                    } } }
                    let channels = levels.map { pow(2,$0) }, sum = channels.reduce(0,+)
                    colours.append(channels.map { $0/sum })
                    observations.append(.init(frame: i,x: x,y: y,channelLevels: levels,confidence: 1,neutralTextureConfidence: SurfaceTracking.contrastPhotometryEnabled ? SurfaceTracking.neutralTextureSupport(samples[i].thumbnail!,x: Double(x),y: Double(y)) : nil))
                }
                let colour = (0..<3).map { c in ExposureMath.median(colours.map { $0[c] }) }
                guard let reference = descriptors.first ?? nil else { continue }
                let valid = observations.compactMap { point -> SurfaceTracking.Observation? in
                    guard zip(colours[point.frame],colour).reduce(0, { $0+abs($1.0-$1.1) }) < 0.06,
                          let descriptor = descriptors[point.frame] else { return nil }
                    let confidence = SurfaceTracking.stationaryConfidence(descriptor,reference)
                    guard confidence > 0.3 else { return nil }
                    return .init(frame: point.frame,x: x,y: y,channelLevels: point.channelLevels,confidence: confidence,neutralTextureConfidence: point.neutralTextureConfidence)
                }
                guard valid.count >= max(4,samples.count*3/4) else { continue }
                for point in SurfaceTracking.lighting(valid,times: samples.map(\.time),radius: radius,mode: mode,strength: strength,global: sharedAnchorEnabled ? global : []) {
                    // A valid trajectory already provides stronger evidence at
                    // this grid location; do not count it twice.
                    if !points[point.frame].contains(where: { abs($0.x-x) <= 2 && abs($0.y-y) <= 2 }) {
                        points[point.frame].append(point)
                    }
                }
            } }
        }
        // A camera can settle within a scene. Establish stationary evidence
        // again from a new fixed footprint instead of requiring that footprint
        // to match the scene's first image after an earlier camera movement.
        // This remains opt-in until encoded motion controls have been checked.
        if cameraMoves,ProcessInfo.processInfo.environment["FRANKLUMA_STATIONARY_EPISODES"] == "1" {
            for y in stride(from: 6,to: h-7,by: spacing) { for x in stride(from: 6,to: w-7,by: spacing) {
                if Task.isCancelled { return [] }
                var episodes: [[SurfaceTracking.Observation]] = []
                var anchor: SurfaceTracking.Descriptor?
                var history: [SurfaceTracking.Observation] = []
                for i in samples.indices {
                    let image = samples[i].thumbnail!
                    guard let shape = SurfaceTracking.descriptor(image,x: x,y: y,half: 6),
                          let centre = SurfaceTracking.descriptor(image,x: x,y: y,half: 2),shape.energy > 0.03 else {
                        if !history.isEmpty { episodes.append(history) }
                        history = [];anchor = nil;continue
                    }
                    let confidence = anchor.map { SurfaceTracking.stationaryContrastConfidence(shape,$0) } ?? 0.65
                    let same = confidence > 0.3
                    if !same {
                        if !history.isEmpty { episodes.append(history) }
                        history = [];anchor = nil
                    }
                    if anchor == nil { anchor = shape }
                    history.append(.init(frame: i,x: x,y: y,channelLevels: centre.mean,
                        confidence: same ? confidence : 0.65,
                        neutralTextureConfidence: SurfaceTracking.contrastPhotometryEnabled ? SurfaceTracking.neutralTextureSupport(image,x: Double(x),y: Double(y)) : nil))
                }
                if !history.isEmpty { episodes.append(history) }
                for episode in episodes where episode.count >= 8 {
                    for point in SurfaceTracking.lighting(episode,times: samples.map(\.time),radius: radius,
                        mode: mode,strength: strength,global: sharedAnchorEnabled ? global : []) {
                        if !points[point.frame].contains(where: { abs($0.x-x) <= 2 && abs($0.y-y) <= 2 }) {
                            points[point.frame].append(point)
                        }
                    }
                }
            } }
        }
        var output: [SpatialField] = []
        output.reserveCapacity(samples.count)
        let rowModels = points.map { rowsEnabled ? rowIllumination($0,width: w,height: h,strength: strength) : nil }
        let bandScene = rowModels.contains { $0 != nil }
        for i in samples.indices {
            if Task.isCancelled { return [] }
            var field = SpatialField()
            field.cameraMotion = cameraMoves
            let rgb = samples[i].thumbnail!.rgb
            var sum = [Double](repeating: 0, count: w*h*3), squares = sum
            var weights = [Double](repeating: 0, count: w*h)
            for point in points[i] {
                let centre = (point.y*w+point.x)*3
                for y in max(0,point.y-5)...min(h-1,point.y+5) { for x in max(0,point.x-5)...min(w-1,point.x+5) {
                    let pixel = y*w+x
                    var colour = 0.0
                    for c in 0..<3 {
                        let a = max(0.003,Double(rgb[pixel*3+c])), b = max(0.003,Double(rgb[centre+c]))
                        colour += pow(log2(a/b),2)
                    }
                    let distance = Double((x-point.x)*(x-point.x)+(y-point.y)*(y-point.y))
                    let weight = point.confidence * exp(-distance/12-colour/0.18)
                    weights[pixel] += weight
                    for c in 0..<3 {
                        sum[pixel*3+c] += weight*point.channelEV[c]
                        squares[pixel*3+c] += weight*pow(point.channelEV[c],2)
                    }
                } }
            }
            // Sensor-coordinate bands can coexist with camera motion. The row
            // model already demands independent, full-width RGB consensus;
            // movement alone must not disable that evidence.
            let rows = rowModels[i]
            let shared = rows == nil ? sharedExposure(points[i],global: global[i],strength: strength) : global[i]
            field.sharedExposureEV = shared
            let gains = sum.indices.map { k -> Float in
                let weight = weights[k/3]
                var reliability = 0.0
                var correction = global[i]
                if weight > 0.000001 {
                    correction = sum[k]/weight
                    let variance = max(0,squares[k]/weight-pow(correction,2))
                    reliability = min(1,weight/0.5)*exp(-variance/max(0.000000000001,strength*strength)/0.04)
                }
                if weight <= 0.02 {
                    // A flat interior cannot establish motion by itself. Use
                    // verified observations of the same material elsewhere in
                    // this frame, rather than interpreting missing flow as zero
                    // lighting change or borrowing a different object's gain.
                    let pixel = k/3, channel = k%3
                    var best = 0.12, candidates: [(ev: Double, confidence: Double)] = []
                    for point in points[i] {
                        let centre = (point.y*w+point.x)*3
                        let errors = (0..<3).map { c in
                            log2(max(0.003,Double(rgb[pixel*3+c]))/max(0.003,Double(rgb[centre+c])))
                        }
                        let common = errors.reduce(0,+)/3
                        let error = errors.reduce(0) { $0+pow($1-common,2) } + 0.02*common*common
                        let distance = Double((pixel%w-point.x)*(pixel%w-point.x)+(pixel/w-point.y)*(pixel/w-point.y))
                        let score = error + distance/Double(w*w+h*h)*0.02
                        if score < best-0.005 { best = score; candidates = [(point.channelEV[channel],point.confidence)] }
                        else if score <= best+0.005 { candidates.append((point.channelEV[channel],point.confidence)) }
                    }
                    if confidenceTargets {
                        candidates = materialDonors(points[i],rgb: rgb,pixel: pixel,channel: channel,width: w,height: h)
                    }
                    if let consensus = materialConsensus(candidates,strength: strength) {
                        correction = consensus.ev
                        reliability = consensus.reliability
                    }
                }
                if let rows { correction = rows[(k/3)/w][k%3]; reliability = 1 }
                // Spatial controls the local lighting correction, not how much
                // an unchanged object must inherit a background-only flash.
                // At zero the caller deliberately uses its global-only path.
                let amount = max(0,min(1,spatialStrength))
                let total = shared+(correction-shared)*reliability*amount
                return Float(total-global[i])
            }
            let coherentGains = rows == nil ? regularizedGains(gains,guide: rgb,width: w,height: h,strength: strength) : gains
            let initialMap = Map(width: w, height: h, channelEV: coherentGains, guide: rgb,rowModel: rows != nil)
            let refinedMap = bandScene ? initialMap : refined(initialMap,points: points[i],global: global[i],shared: shared,
                strength: strength,spatialStrength: spatialStrength,colourStrength: colourEnabled ? colourStrength : 0)
            // Colour is applied once, after all independently fitted RGB
            // updates, so refinement cannot re-enable colour at zero or
            // silently change the meaning of a partial Colour setting.
            let colourGains = colourAdjustedGains(refinedMap.channelEV,guide: rgb,amount: colourEnabled ? colourStrength : 0)
            field.surface = Map(width: w,height: h,channelEV: colourGains,guide: rgb,rowModel: rows != nil)
            field.alignments = links[i]
            for p in field.confidence.indices {
                let x = min(w-1,Int((Double(p%24)+0.5)/24*Double(w)))
                let y = min(h-1,Int((Double(p/24)+0.5)/14*Double(h)))
                field.confidence[p] = min(1,weights[y*w+x])
                field.motion[p] = 1-field.confidence[p]
                let k = (y*w+x)*3
                let applied = field.surface!.channelEV
                field.applied[p] = 0.2126*Double(applied[k])+0.7152*Double(applied[k+1])+0.0722*Double(applied[k+2])
                field.requested[p] = field.applied[p]
            }
            field.fallback = points[i].isEmpty ? "No supported surface trajectory" : nil
            output.append(field)
        }
        return output
    }
}

enum SpatialLighting {
    static func translation(_ source: SpatialThumbnail, _ reference: SpatialThumbnail) -> SpatialAlignment {
        let shift = register(Frame(source),Frame(reference))
        return SpatialAlignment(reference: 0,dx: shift.dx,dy: shift.dy,error: shift.error,accepted: shift.accepted)
    }
    private struct Frame {
        let thumb: SpatialThumbnail
        let luminance: [Double]
        let log: [Double]
        let red: [Double]
        let green: [Double]
        let gradientX: [Double]
        let gradientY: [Double]
        let features: [Int]
        init(_ t: SpatialThumbnail) {
            thumb = t; luminance = t.light
            log = luminance.map { log2(max(0.001, $0)) }
            red = stride(from: 0, to: t.rgb.count, by: 3).map { i in
                Double(t.rgb[i]) / max(0.001, Double(t.rgb[i] + t.rgb[i+1] + t.rgb[i+2]))
            }
            green = stride(from: 0, to: t.rgb.count, by: 3).map { i in
                Double(t.rgb[i+1]) / max(0.001, Double(t.rgb[i] + t.rgb[i+1] + t.rgb[i+2]))
            }
            var gx = [Double](repeating: 0, count: luminance.count), gy = gx
            for y in 1..<(t.height-1) { for x in 1..<(t.width-1) {
                let p = y*t.width+x
                gx[p] = log[p+1]-log[p-1]; gy[p] = log[p+t.width]-log[p-t.width]
            } }
            gradientX = gx; gradientY = gy
            var positions: [Int] = []
            for y in stride(from: 4, to: t.height-4, by: 3) { for x in stride(from: 4, to: t.width-4, by: 3) {
                let p = y*t.width+x
                if luminance[p] > 0.02, abs(gx[p])+abs(gy[p]) > 0.03 { positions.append(p) }
            } }
            features = positions
        }
    }

    private static let sampleBasis = (0..<336).map { p in
        SpatialField.basis(x: (Double(p % 24)+0.5)/24, y: (Double(p / 24)+0.5)/14, columns: 9, rows: 6)
    }
    private static let supportWeights = (0..<54).map { node in
        (0..<336).map { p in
            let dx = (Double(p % 24)+0.5)/24-Double(node % 9)/8
            let dy = (Double(p / 24)+0.5)/14-Double(node / 9)/5
            return exp(-0.5*(pow(dx/0.12,2)+pow(dy/0.16,2)))
        }
    }

    /// Independent patch targets from original light, never from neighbours
    /// that have already received the scene-wide exposure adjustment.
    private static func temporalTargets(samples: [ExposureSample], radius: Double, mode: NormalisationMode) -> [[Double]] {
        guard let thumbnail = samples.first?.thumbnail, thumbnail.width >= 24, thumbnail.height >= 20,
              samples.allSatisfy({ $0.thumbnail?.width == thumbnail.width && $0.thumbnail?.height == thumbnail.height }) else { return [] }
        let w = thumbnail.width, h = thumbnail.height
        var means: [[Double]] = [], reds: [[Double]] = [], greens: [[Double]] = []
        means.reserveCapacity(samples.count); reds.reserveCapacity(samples.count); greens.reserveCapacity(samples.count)
        for sample in samples {
            if Task.isCancelled { return [] }
            let rgb = sample.thumbnail!.rgb
            var patches: [Double] = [], red: [Double] = [], green: [Double] = []
            patches.reserveCapacity(336)
            for row in 0..<14 { for col in 0..<24 {
                let x = min(w-3, max(2, Int((Double(col)+0.5)/24*Double(w))))
                let y = min(h-3, max(2, Int((Double(row)+0.5)/14*Double(h))))
                var r = 0.0, g = 0.0, b = 0.0
                for dy in -2...2 { for dx in -2...2 {
                    let p = ((y+dy)*w+x+dx)*3
                    r += Double(rgb[p]); g += Double(rgb[p+1]); b += Double(rgb[p+2])
                } }
                patches.append((0.2126*r+0.7152*g+0.0722*b)/25)
                red.append(r/max(0.001,r+g+b)); green.append(g/max(0.001,r+g+b))
            } }
            means.append(patches); reds.append(red); greens.append(green)
        }
        var targets = means
        for patch in 0..<336 {
            if Task.isCancelled { return [] }
            let red = ExposureMath.median(reds.map { $0[patch] })
            let green = ExposureMath.median(greens.map { $0[patch] })
            let anchor = samples.indices.min {
                abs(reds[$0][patch]-red)+abs(greens[$0][patch]-green) < abs(reds[$1][patch]-red)+abs(greens[$1][patch]-green)
            }!
            let x = min(w-3, max(2, Int((Double(patch % 24)+0.5)/24*Double(w))))
            let y = min(h-3, max(2, Int((Double(patch / 24)+0.5)/14*Double(h))))
            let valid = samples.indices.filter { i in
                let colour = abs(reds[i][patch]-red)+abs(greens[i][patch]-green)
                guard means[i][patch] > 0.015 else { return false }
                if colour < 0.04 { return true }
                // Additive illumination changes chromaticity even when the
                // physical surface is unchanged. Require matching texture.
                return colour < 0.12 && textureCorrelation(samples[i].thumbnail!, samples[anchor].thumbnail!, x: x, y: y) > 0.97
            }
            for i in samples.indices { targets[i][patch] = .nan }
            guard valid.count >= 3 else { continue }
            let series = valid.map { ExposureSample(time: samples[$0].time,
                level: log2(max(0.001, means[$0][patch])), segment: samples[$0].segment) }
            let correction = ExposureMath.curve(samples: series, radius: radius, strength: 1, mode: mode)
            for (index, i) in valid.enumerated() { targets[i][patch] = means[i][patch]*pow(2,correction.stops[index]) }
        }
        return targets
    }

    /// Work on independent ranges with a six-frame halo. This reproduces the
    /// serial neighbour selection while using multiple cores on long shots.
    static func estimateAsync(samples: [ExposureSample], global: [Double], radius: Double, strength: Double,
                              region: CGRect? = nil, previous: [SpatialField] = [], chunkSize: Int = 120, mode: NormalisationMode = .smooth) async -> [SpatialField] {
        let chunkSize = max(1, chunkSize)
        guard samples.count > chunkSize, samples.count == global.count, strength > 0 else {
            return estimate(samples: samples, global: global, radius: radius, strength: strength, region: region, previous: previous, mode: mode)
        }
        let targets = temporalTargets(samples: samples, radius: radius, mode: mode)
        if Task.isCancelled { return [] }
        let workers = min(6, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))
        return await withTaskGroup(of: (Int, [SpatialField]).self) { group in
            var output = [SpatialField](repeating: SpatialField(), count: samples.count)
            var next = 0
            func enqueue(_ start: Int) {
                let end = min(samples.count, start + chunkSize)
                let lower = max(0, start - 6), upper = min(samples.count, end + 6)
                group.addTask {
                    if Task.isCancelled { return (start, []) }
                    let old = previous.count == samples.count ? previous[lower..<upper].map { field -> SpatialField in
                        var field = field
                        field.alignments = field.alignments.map {
                            SpatialAlignment(reference: $0.reference-lower, dx: $0.dx, dy: $0.dy, error: $0.error, accepted: $0.accepted)
                        }
                        return field
                    } : []
                    let fields = estimate(samples: Array(samples[lower..<upper]), global: Array(global[lower..<upper]),
                                          radius: radius, strength: strength, region: region, previous: old, mode: mode, targets: targets.isEmpty ? [] : Array(targets[lower..<upper]))
                    guard fields.count == upper-lower else { return (start, []) }
                    return (start, fields[(start-lower)..<(end-lower)].map { field -> SpatialField in
                        var field = field
                        field.alignments = field.alignments.map {
                            SpatialAlignment(reference: $0.reference+lower, dx: $0.dx, dy: $0.dy, error: $0.error, accepted: $0.accepted)
                        }
                        return field
                    })
                }
            }
            for _ in 0..<workers where next < samples.count { enqueue(next); next += chunkSize }
            for await (start, fields) in group {
                if Task.isCancelled { group.cancelAll(); continue }
                for (offset, field) in fields.enumerated() { output[start+offset] = field }
                if next < samples.count { enqueue(next); next += chunkSize }
            }
            return Task.isCancelled ? [] : output
        }
    }

    static func estimate(samples: [ExposureSample], global: [Double], radius: Double, strength: Double,
                         region: CGRect? = nil, previous: [SpatialField] = [], mode: NormalisationMode = .smooth, targets: [[Double]] = []) -> [SpatialField] {
        if Task.isCancelled { return [] }
        guard !samples.isEmpty, samples.count == global.count, samples.allSatisfy({ $0.thumbnail != nil }), strength > 0 else {
            let disabled = SpatialField()
            return samples.map { _ in disabled }
        }
        let w = samples[0].thumbnail!.width, h = samples[0].thumbnail!.height
        guard w >= 24, h >= 20, samples.allSatisfy({ $0.thumbnail!.width == w && $0.thumbnail!.height == h }) else {
            let disabled = SpatialField()
            return samples.map { _ in disabled }
        }
        let targets = targets.count == samples.count ? targets : temporalTargets(samples: samples, radius: radius, mode: mode)
        guard targets.count == samples.count, !Task.isCancelled else { return [] }
        // Only the current frame and its six local references need derived
        // luminance/gradient arrays. Keep that working set bounded on long shots.
        var frames: [Int: Frame] = [:]
        func prepare(_ index: Int) {
            if frames[index] == nil { frames[index] = Frame(samples[index].thumbnail!) }
        }
        var result: [SpatialField] = []
        result.reserveCapacity(samples.count)
        for i in samples.indices {
            if Task.isCancelled { return [] }
            var field = SpatialField()
            let neighbours = neighbourIndices(samples: samples, index: i, radius: radius)
            let needed = Set(neighbours + [i])
            frames = frames.filter { needed.contains($0.key) }
            for index in needed { prepare(index) }
            for j in neighbours {
                if previous.count == samples.count,
                   let alignment = previous[i].alignments.first(where: { $0.reference == j }) {
                    field.alignments.append(alignment)
                    continue
                }
                let shift = register(frames[i]!, frames[j]!)
                field.alignments.append(SpatialAlignment(reference: j, dx: shift.dx, dy: shift.dy, error: shift.error, accepted: shift.accepted))
            }
            let accepted = field.alignments.filter(\.accepted)
            guard accepted.count >= 2 else {
                field.fallback = "Too few aligned neighbouring frames"
                result.append(field); continue
            }
            var offsetTargets = [Double](repeating: 0, count: field.confidence.count)
            var spreads = offsetTargets
            var toneWeights = offsetTargets
            var patchRed = offsetTargets, patchGreen = offsetTargets, colourTolerance = offsetTargets
            for row in 0..<field.sampleRows { for col in 0..<field.sampleColumns {
                let index = row * field.sampleColumns + col
                let nx = (Double(col) + 0.5) / Double(field.sampleColumns)
                let ny = (Double(row) + 0.5) / Double(field.sampleRows)
                if let region, !region.contains(CGPoint(x: nx, y: ny)) { continue }
                let x = min(w-3, max(2, Int(nx * Double(w))))
                let y = min(h-3, max(2, Int(ny * Double(h))))
                var gains: [Double] = [], matchedMeans: [Double] = [], alignedMeans: [Double] = [], weights: [Double] = []
                var texturedMatches = 0
                let patch = (-2...2).flatMap { dy in (-2...2).map { dx in frames[i]!.luminance[(y+dy)*w+x+dx] } }
                let current = patch.reduce(0,+)/Double(patch.count)
                patchRed[index] = ExposureMath.median((-2...2).flatMap { dy in (-2...2).map { dx in frames[i]!.red[(y+dy)*w+x+dx] } })
                patchGreen[index] = ExposureMath.median((-2...2).flatMap { dy in (-2...2).map { dx in frames[i]!.green[(y+dy)*w+x+dx] } })
                let colourErrors = (-2...2).flatMap { dy in (-2...2).map { dx in
                    let p = (y+dy)*w+x+dx
                    return abs(frames[i]!.red[p]-patchRed[index])+abs(frames[i]!.green[p]-patchGreen[index])
                } }.sorted()
                colourTolerance[index] = min(0.30,colourErrors[22])
                spreads[index] = sqrt(patch.map { pow($0-current,2) }.reduce(0,+)/Double(patch.count))
                field.before[index] = current
                for alignment in accepted {
                    let j = alignment.reference
                    let match = compare(frames[i]!, frames[j]!, x: x, y: y, dx: alignment.dx, dy: alignment.dy)
                    if match.confidence > 0 {
                        gains.append(match.delta)
                        let mean = current*pow(2,match.delta)+match.offset
                        matchedMeans.append(mean)
                        alignedMeans.append(mean*pow(2,global[j]))
                        weights.append(match.confidence)
                        if match.textured { texturedMatches += 1 }
                    }
                }
                let fraction = Double(gains.count) / Double(accepted.count)
                field.motion[index] = 1 - fraction
                guard gains.count >= 2, fraction >= 0.5 else { continue }
                // Texture matches establish motion/contrast support. Brightness
                // is anchored independently, so a globally overcorrected floor
                // in a neighbouring flash cannot become this frame's target.
                // Fixed-coordinate baselines are unsuitable for camera moves.
                // Registered raw patch means retain their physical correspondence.
                let translated = accepted.contains { $0.dx != 0 || $0.dy != 0 }
                let desired = translated ? ExposureMath.median(alignedMeans) : targets[i][index]
                guard desired.isFinite else { field.motion[index] = 1; continue }
                // Gain and offset describe the same reference, so normalise
                // its contrast to the independent target before combining fits.
                // Raw gain medians alone would follow alternating bright/dark
                // neighbours even when their mean target is already stable.
                let contrast = zip(gains, matchedMeans).map {
                    $0 + log2(max(0.001, desired)/max(0.001, $1))
                }
                let residual = ExposureMath.median(contrast) - global[i]
                let confidence = ExposureMath.median(weights) * fraction
                guard confidence > 0.25, current > 0.015 else { continue }
                field.confidence[index] = confidence
                field.requested[index] = max(-0.75, min(0.75, residual))
                offsetTargets[index] = desired - current * pow(2, global[i] + field.requested[index])
                field.reference[index] = desired
                if texturedMatches >= 2 { toneWeights[index] = confidence*Double(texturedMatches)/Double(gains.count) }

            } }
            // Erode uncertain boundary patches beside motion/occlusion. A patch
            // with consistent correspondence must keep its own lighting target;
            // a moving neighbour does not invalidate that physical surface.
            let motion = field.motion
            for row in 0..<field.sampleRows { for col in 0..<field.sampleColumns {
                let index = row * field.sampleColumns + col
                if motion[index] > 0.5 { field.confidence[index] = 0; continue }
                var movingNeighbours = 0
                for yy in max(0,row-1)...min(field.sampleRows-1,row+1) {
                    for xx in max(0,col-1)...min(field.sampleColumns-1,col+1) {
                        if motion[yy*field.sampleColumns+xx] > 0.65 { movingNeighbours += 1 }
                    }
                }
                if movingNeighbours > 0, motion[index] > 0.25 { field.confidence[index] *= 0.4 }
            } }
            guard field.confidence.filter({ $0 > 0.25 }).count >= 18 else {
                field.fallback = "Insufficient unoccluded background support"
                result.append(field); continue
            }
            // Keep verified affine maps at patch resolution for uniform surfaces.
            // Coarse gain/offset fitting can match a patch mean while losing its
            // contrast; source-colour guidance in the renderer protects edges.
            let patchConfidence = field.confidence.indices.map { p in
                field.confidence[p] > 0.25 && toneWeights[p] > 0.25 ? min(1,toneWeights[p]/0.5) : 0
            }
            field.patchTone = SpatialPatchTone(
                stops: field.requested.map { $0*strength }, offsets: offsetTargets.map { $0*strength },
                red: patchRed, green: patchGreen, confidence: patchConfidence, colourTolerance: colourTolerance)
            var exposureField = field
            exposureField.requested = field.requested.indices.map { p in
                log2(max(0.25, pow(2,field.requested[p]) + offsetTargets[p] / max(0.02,field.before[p]*pow(2,global[i]))))
            }
            field.exposureStops = fit(field: exposureField).map { max(-0.9,min(0.9,$0))*strength }
            let fitted = fitTone(field: field, offsets: offsetTargets, spreads: spreads, global: global[i])
            field.stops = fitted.gains.map { log2(max(0.25, $0)) * strength }
            field.offsets = fitted.offsets.map { $0 * strength }
            // Fade unsupported portions smoothly towards global correction.
            // Do not extrapolate a large gain into an occluded/clipped corner.
            for y in 0..<field.rows { for x in 0..<field.columns {
                var support=0.0, total=0.0
                for r in 0..<field.sampleRows { for c in 0..<field.sampleColumns {
                    let weight = supportWeights[y*field.columns+x][r*field.sampleColumns+c]
                    // Confidence already weights the fit. Fade by coverage of
                    // reliable anchors, rather than weakening their gain again
                    // when neighbouring foreground patches have been excluded.
                    if field.confidence[r*field.sampleColumns+c] > 0.25 { support += weight }
                    total += weight
                } }
                let supportWeight = min(1, support/max(0.00001,total)/0.35)
                field.stops[y*field.columns+x] *= supportWeight
                field.offsets[y*field.columns+x] *= supportWeight
                field.exposureStops[y*field.columns+x] *= supportWeight
            } }
            // Bound gradients to avoid abrupt local contrast changes.
            for _ in 0..<4 {
                for y in 0..<field.rows { for x in 0..<field.columns {
                    let p = y*field.columns+x
                    for q in [x+1 < field.columns ? p+1 : p, y+1 < field.rows ? p+field.columns : p] where q != p {
                        let difference = field.stops[p] - field.stops[q]
                        if abs(difference) > 0.18 {
                            let adjustment = (abs(difference)-0.18)/2 * (difference > 0 ? 1.0 : -1.0)
                            field.stops[p] -= adjustment; field.stops[q] += adjustment
                        }
                    }
                } }
            }
            field.fallback = nil
            for row in 0..<field.sampleRows { for col in 0..<field.sampleColumns {
                field.applied[row*field.sampleColumns+col] = field.value(x: (Double(col)+0.5)/Double(field.sampleColumns), y: (Double(row)+0.5)/Double(field.sampleRows))
            } }
            result.append(field)
        }
        return result
    }

    static func neighbourIndices(samples: [ExposureSample], index: Int, radius: Double) -> [Int] {
        let window = max(0.25, radius)+0.000001
        var neighbours: [Int] = []
        var distance = 1
        var leftOpen = true, rightOpen = true
        while neighbours.count < 6, leftOpen || rightOpen {
            let left = index-distance, right = index+distance
            if leftOpen {
                leftOpen = left >= 0 && samples[left].segment == samples[index].segment && samples[index].time-samples[left].time <= window
                if leftOpen { neighbours.append(left) }
            }
            if rightOpen, neighbours.count < 6 {
                rightOpen = right < samples.count && samples[right].segment == samples[index].segment && samples[right].time-samples[index].time <= window
                if rightOpen { neighbours.append(right) }
            }
            distance += 1
        }
        return neighbours
    }

    /// Bounded translation registration on log-luminance gradients. Large
    /// motion, parallax or rotation that fails this test falls back safely.
    private static func register(_ a: Frame, _ b: Frame) -> (dx: Int, dy: Int, error: Double, accepted: Bool) {
        let w = a.thumb.width, h = a.thumb.height
        func cost(_ dx: Int, _ dy: Int) -> Double {
            var sum = 0.0, count = 0
            for p in a.features {
                let y = p/w, x = p % w
                let xx=x+dx, yy=y+dy
                guard xx>1, xx<w-2, yy>1, yy<h-2 else { continue }
                let q=yy*w+xx
                guard b.luminance[q]>0.02 else { continue }
                let residual=abs(a.gradientX[p]-b.gradientX[q])+abs(a.gradientY[p]-b.gradientY[q])
                sum += min(0.3,residual); count += 1
            }
            return count >= 12 ? sum/Double(count) : 0.3
        }
        var best=(dx:0,dy:0,error:cost(0,0))
        for dy in stride(from: -8, through: 8, by: 1) { for dx in stride(from: -12, through: 12, by: 1) {
            let value=cost(dx,dy) + 0.0001*Double(abs(dx)+abs(dy))
            if value < best.error { best=(dx,dy,value) }
        } }
        // Flat synthetic/background images have no registration features. Only
        // accept zero translation when chromaticity and local structure agree.
        if best.error >= 0.29 {
            let centre=compare(a,b,x:w/2,y:h/2,dx:0,dy:0)
            if centre.confidence>0.8 { return (0,0,0,true) }
        }
        return (best.dx,best.dy,best.error,best.error < (best.dx == 0 && best.dy == 0 ? 0.20 : 0.12) && abs(best.dx)<12 && abs(best.dy)<8)
    }

    /// Exposure/offset invariant patch structure. Flat patches cannot prove
    /// correspondence; colour checks continue to protect those regions.
    private static func textureCorrelation(_ a: SpatialThumbnail, _ b: SpatialThumbnail, x: Int, y: Int) -> Double {
        let w = a.width
        var aa: [Double] = [], bb: [Double] = []
        for yy in -2...2 { for xx in -2...2 {
            let p = ((y+yy)*w+x+xx)*3
            aa.append(0.2126*Double(a.rgb[p])+0.7152*Double(a.rgb[p+1])+0.0722*Double(a.rgb[p+2]))
            bb.append(0.2126*Double(b.rgb[p])+0.7152*Double(b.rgb[p+1])+0.0722*Double(b.rgb[p+2]))
        } }
        let ma = aa.reduce(0,+)/25, mb = bb.reduce(0,+)/25
        var va = 0.0, vb = 0.0, covariance = 0.0
        for i in aa.indices {
            let da = aa[i]-ma, db = bb[i]-mb
            va += da*da; vb += db*db; covariance += da*db
        }
        guard va/25 > 0.00002, vb/25 > 0.00002 else { return 0 }
        return covariance/sqrt(va*vb)
    }

    private static func compare(_ a: Frame, _ b: Frame, x: Int, y: Int, dx: Int, dy: Int) -> (delta: Double, offset: Double, confidence: Double, textured: Bool) {
        let w=a.thumb.width,h=a.thumb.height
        guard x+dx>=2, x+dx<w-2, y+dy>=2, y+dy<h-2 else { return (0,0,0,false) }
        var ratios:[Double]=[], colours:[Double]=[], pairs:[(Double, Double)]=[]
        for yy in -2...2 { for xx in -2...2 {
            let p=(y+yy)*w+x+xx, q=(y+yy+dy)*w+x+xx+dx
            let ap=p*3,bp=q*3
            guard a.luminance[p]>0.015,b.luminance[q]>0.015,
                  max(a.thumb.rgb[ap],a.thumb.rgb[ap+1],a.thumb.rgb[ap+2])<0.97,
                  max(b.thumb.rgb[bp],b.thumb.rgb[bp+1],b.thumb.rgb[bp+2])<0.97 else { continue }
            ratios.append(b.log[q]-a.log[p])
            pairs.append((a.luminance[p], b.luminance[q]))
            colours.append(abs(a.red[p]-b.red[q])+abs(a.green[p]-b.green[q]))
        } }
        guard ratios.count>=12 else { return (0,0,0,false) }
        let delta=ExposureMath.median(ratios)
        let residual=ExposureMath.median(ratios.map { abs($0-delta) })
        let colour=ExposureMath.median(colours)
        let meanA = pairs.map { $0.0 }.reduce(0,+)/Double(pairs.count)
        let meanB = pairs.map { $0.1 }.reduce(0,+)/Double(pairs.count)
        let varianceA = pairs.map { pow($0.0-meanA,2) }.reduce(0,+)
        let varianceB = pairs.map { pow($0.1-meanB,2) }.reduce(0,+)
        let covarianceAB = pairs.map { ($0.0-meanA)*($0.1-meanB) }.reduce(0,+)
        let correlation = varianceA > 0.0005 && varianceB > 0.0005 ? covarianceAB/sqrt(varianceA*varianceB) : 0
        let sameTexture = correlation > 0.97 && colour < 0.12
        guard ratios.count >= 18 || sameTexture else { return (delta,0,0,false) }
        guard colour < 0.055 || sameTexture else { return (delta,0,0,false) }
        // Estimate the gain from matched linear-light energy, rather than
        // the median pixel ratio. The latter overweights dark crevices on
        // textured surfaces and can turn a dark floor frame into a bright one.
        // Downweight inconsistent pixel pairs before summing to retain robustness
        // against small occlusions and misregistration.
        var source = 0.0, target = 0.0, support = 0.0
        for (index, pair) in pairs.enumerated() {
            let weight = min(1, max(0.08, 3*residual) / max(0.000001, abs(ratios[index]-delta)))
            source += weight * pair.0; target += weight * pair.1; support += weight
        }
        guard support >= (sameTexture ? 12 : 18), source > 0 else { return (delta, 0, 0,false) }
        let scalar = target/source
        var gain = scalar, offset = 0.0
        // A diffuse-light change can affect bright studs and dark recesses
        // differently. Only introduce an offset when matched texture supports
        // a materially better affine fit than an exposure-only fit.
        let meanX = pairs.map { $0.0 }.reduce(0,+)/Double(pairs.count)
        let meanY = pairs.map { $0.1 }.reduce(0,+)/Double(pairs.count)
        let variance = pairs.map { pow($0.0-meanX,2) }.reduce(0,+)
        if variance/Double(pairs.count) > (sameTexture ? 0.00002 : 0.0004) {
            let covariance = pairs.map { ($0.0-meanX)*($0.1-meanY) }.reduce(0,+)
            let slope = covariance/variance
            let intercept = meanY-slope*meanX
            let scalarError = pairs.map { pow($0.1-scalar*$0.0,2) }.reduce(0,+)
            let affineError = pairs.map { pow($0.1-slope*$0.0-intercept,2) }.reduce(0,+)
            if slope > (sameTexture ? 0.25 : 0.5), slope < (sameTexture ? 4 : 2), abs(intercept) < 0.25,
               affineError < scalarError * 0.4 {
                gain = slope; offset = intercept
            }
        }
        let fitResidual = ExposureMath.median(pairs.map { abs($0.1 - (gain*$0.0+offset)) / max(0.02,$0.1) })
        guard fitResidual < 0.07 || (sameTexture && fitResidual < 0.15) else { return (delta,0,0,false) }
        let ordinary = max(0,1-fitResidual/0.09)*max(0,1-colour/0.065)
        let structural = sameTexture ? 0.8*max(0,1-fitResidual/0.2) : 0
        return (log2(gain),offset,max(ordinary,structural),sameTexture)
    }

    /// Fit gain and offset together: every background patch constrains its
    /// corrected mean, and textured patches additionally constrain contrast.
    /// Separate fits can satisfy neither after spatial interpolation.
    private static func fitTone(field: SpatialField, offsets: [Double], spreads: [Double], global: Double) -> (gains: [Double], offsets: [Double]) {
        let nodes = field.columns * field.rows, n = nodes * 2
        let globalGain = pow(2, global)
        var matrix = [Double](repeating: 0, count: n*n), rhs = [Double](repeating: 0, count: n)
        func add(_ terms: [(Int,Double)], _ weight: Double, _ target: Double) {
            for (a,wa) in terms {
                rhs[a] += weight*wa*target
                for (b,wb) in terms { matrix[a*n+b] += weight*wa*wb }
            }
        }
        for r in 0..<field.sampleRows { for c in 0..<field.sampleColumns {
            let p=r*field.sampleColumns+c
            guard field.confidence[p] > 0 else { continue }
            let basis = sampleBasis[p]
            let light=field.before[p]*globalGain
            let gain=pow(2,field.requested[p])-1
            let meanTerms=basis.map { ($0.0,$0.1*light*4) } + basis.map { ($0.0+nodes,$0.1) }
            add(meanTerms,field.confidence[p],(gain*light+offsets[p])*4)
            let spread=spreads[p]*globalGain*4
            add(basis.map { ($0.0,$0.1*spread) },field.confidence[p],gain*spread)
        } }
        for channel in 0..<2 { for y in 0..<field.rows { for x in 0..<field.columns {
            let p=channel*nodes+y*field.columns+x
            add([(p,1)],0.002,0)
            if x>0 && x<field.columns-1 { add([(p-1,1),(p,-2),(p+1,1)],0.10,0) }
            if y>0 && y<field.rows-1 { add([(p-field.columns,1),(p,-2),(p+field.columns,1)],0.10,0) }
        } } }
        var lower=[Double](repeating:0,count:n*n)
        for i in 0..<n { for j in 0...i {
            var value=matrix[i*n+j]
            for k in 0..<j { value -= lower[i*n+k]*lower[j*n+k] }
            lower[i*n+j] = i==j ? sqrt(max(0.000001,value)) : value/lower[j*n+j]
        } }
        var temp=[Double](repeating:0,count:n), solution=temp
        for i in 0..<n { var value=rhs[i];for j in 0..<i { value -= lower[i*n+j]*temp[j] };temp[i]=value/lower[i*n+i] }
        for i in stride(from:n-1,through:0,by:-1) { var value=temp[i];if i+1<n { for j in (i+1)..<n { value -= lower[j*n+i]*solution[j] } };solution[i]=value/lower[i*n+i] }
        return (Array(solution.prefix(nodes)).map { max(0.6,min(1.6,1+$0)) }, Array(solution.suffix(nodes)).map { max(-0.25,min(0.25,$0/4)) })
    }

    /// Robust weighted least squares with a bending penalty and a weak zero
    /// prior. Preserve supported regional flashes instead of treating their
    /// concentrated residuals as outliers. Unsupported cells relax towards
    /// global correction.
    static func fit(field: SpatialField) -> [Double] {
        let n=field.columns*field.rows
        var solution=[Double](repeating:0,count:n)
        for iteration in 0..<3 {
            var matrix=[Double](repeating:0,count:n*n), rhs=[Double](repeating:0,count:n)
            func add(_ terms:[(Int,Double)], _ weight:Double, _ target:Double) {
                for (a,wa) in terms {
                    rhs[a] += weight*wa*target
                    for (b,wb) in terms { matrix[a*n+b] += weight*wa*wb }
                }
            }
            for r in 0..<field.sampleRows { for c in 0..<field.sampleColumns {
                let p=r*field.sampleColumns+c
                guard field.confidence[p]>0 else { continue }
                let basis = sampleBasis[p]
                let prediction=basis.reduce(0) { $0+solution[$1.0]*$1.1 }
                let error=abs(prediction-field.requested[p])
                let robust=iteration==0 ? 1 : min(1,0.20/max(0.0001,error))
                add(basis,field.confidence[p]*robust,field.requested[p])
            } }
            for y in 0..<field.rows { for x in 0..<field.columns {
                let p=y*field.columns+x
                add([(p,1)],0.002,0)
                if x>0 && x<field.columns-1 { add([(p-1,1),(p,-2),(p+1,1)],0.08,0) }
                if y>0 && y<field.rows-1 { add([(p-field.columns,1),(p,-2),(p+field.columns,1)],0.08,0) }
            } }
            // Cholesky solve; positive priors make the system definite.
            var lower=[Double](repeating:0,count:n*n)
            for i in 0..<n { for j in 0...i {
                var value=matrix[i*n+j]
                for k in 0..<j { value -= lower[i*n+k]*lower[j*n+k] }
                lower[i*n+j] = i==j ? sqrt(max(0.000001,value)) : value/lower[j*n+j]
            } }
            var temp=[Double](repeating:0,count:n)
            for i in 0..<n { var value=rhs[i];for j in 0..<i { value -= lower[i*n+j]*temp[j] };temp[i]=value/lower[i*n+i] }
            for i in stride(from:n-1,through:0,by:-1) { var value=temp[i];if i+1<n { for j in (i+1)..<n { value -= lower[j*n+i]*solution[j] } };solution[i]=value/lower[i*n+i] }
        }
        return solution
    }
}

/// Experimental shared residual correction. Unsupported transitions retain
/// exactly the same gain difference; only source pixels are rendered.
/// Source-only identity evidence that tolerates a smooth illumination gradient.
/// Removing a plane is not sufficient proof of physical surface identity; pair
/// geometry and source texture validation remain required by callers.
enum PersistentLocalFlash {
    static func apply(samples: [ExposureSample], stops: [Double], fields: [SpatialField], options: SceneSettings) -> [SpatialField] {
        guard samples.count > 3, samples.count == fields.count, stops.count == fields.count,
              options.strength > 0, options.spatialStrength > 0,
              let first = samples.first?.thumbnail,
              samples.allSatisfy({ $0.thumbnail?.width == first.width && $0.thumbnail?.height == first.height }),
              fields.allSatisfy({ $0.surface?.width == first.width && $0.surface?.height == first.height && $0.surface?.rowModel != true }) else { return fields }
        let w = first.width, h = first.height, count = samples.count
        let debug = ProcessInfo.processInfo.environment["FRANKLUMA_PERSISTENT_LOCAL_DEBUG"] == "1"
        let images = samples.map { $0.thumbnail! }
        let rendered: [SpatialThumbnail] = images.indices.map { i in
            let image = images[i], map = fields[i].surface!
            var rgb = [Float](); rgb.reserveCapacity(image.rgb.count)
            for y in 0..<h { for x in 0..<w {
                let p = (y*w+x)*3
                rgb += SpatialRenderer.surfaceRGB((0..<3).map { Double(image.rgb[p+$0]) },
                    x: (Double(x)+0.5)/Double(w), y: (Double(y)+0.5)/Double(h),
                    map: map, global: stops[i]+(fields[i].brightnessEV ?? 0)).map(Float.init)
            } }
            return SpatialThumbnail(width: w,height: h,rgb: rgb)
        }
        let points = stride(from: 6,to: h-7,by: 8).flatMap { y in stride(from: 6,to: w-7,by: 8).map { (x: $0,y: y) } }
        func pixels(_ point: Int) -> [Int] {
            let p = points[point]
            return (-6...6).flatMap { dy in (-6...6).map { dx in (p.y+dy)*w+p.x+dx } }
        }
        let footprints = points.indices.map(pixels)
        func light(_ image: SpatialThumbnail, _ pixel: Int) -> Double {
            0.2126*Double(image.rgb[pixel*3])+0.7152*Double(image.rgb[pixel*3+1])+0.0722*Double(image.rgb[pixel*3+2])
        }
        func step(_ a: SpatialThumbnail, _ b: SpatialThumbnail, _ footprint: [Int]) -> Double {
            log2(footprint.reduce(0.0) { $0+light(b,$1) }/footprint.reduce(0.0) { $0+light(a,$1) })
        }
        var support = Array(repeating: Set<Int>(),count: count), sourceSteps = [Int: Double](), renderedSteps = [Int: Double]()
        for i in 1..<count {
            if Task.isCancelled { return fields }
            let model = SurfaceMotion.estimate(SurfaceMotion.coarse(images[i-1]),SurfaceMotion.coarse(images[i]))
            for j in points.indices {
                let p = points[j], q = model?.point(Double(p.x),Double(p.y)) ?? (Double(p.x),Double(p.y))
                // Initial implementation only claims exact stationary support.
                guard hypot(q.0-Double(p.x),q.1-Double(p.y)) < 0.01,
                      let a = SurfaceTracking.descriptor(images[i-1],x: p.x,y: p.y,half: 6),
                      let b = SurfaceTracking.descriptor(images[i],x: p.x,y: p.y,half: 6),
                      a.energy > 0.03, b.energy > 0.03,
                      zip(a.texture,b.texture).reduce(0.0,{ $0+$1.0*$1.1 })/(Double(a.texture.count)*a.energy*b.energy) > 0.95,
                      footprints[j].allSatisfy({ pixel in
                          (0..<3).allSatisfy { c in rendered[i-1].rgb[pixel*3+c] < 0.8 && rendered[i].rgb[pixel*3+c] < 0.8 }
                      }) else { continue }
                support[i].insert(j)
            }
            if support[i].count >= 12 {
                sourceSteps[i] = ExposureMath.median(support[i].map { step(images[i-1],images[i],footprints[$0]) })
                renderedSteps[i] = ExposureMath.median(support[i].map { step(rendered[i-1],rendered[i],footprints[$0]) })
            }
        }
        var intervals = [(Int,Int)]()
        if debug { print("PERSISTENT_LOCAL support=\(support.map(\.count)) source=\(sourceSteps)") }
        for i in sourceSteps.keys.sorted() {
            let nearby = sourceSteps.filter { abs(samples[$0.key].time-samples[i].time) <= options.radius }.map(\.value)
            guard nearby.count >= 3 else { continue }
            let trend = options.mode == .steady ? 0 : ExposureMath.median(nearby)
            let target = (1-options.strength)*sourceSteps[i]!+options.strength*trend
            guard abs(sourceSteps[i]!-trend) >= 0.08,
                  abs(renderedSteps[i]!-target) >= 0.025*options.strength else { continue }
            let start = max(0,(0..<i).last(where: { samples[$0].time < samples[i].time-max(0.3,options.radius) }) ?? 0)
            let end = min(count-1,(i..<count).first(where: { samples[$0].time > samples[i].time+max(0.3,options.radius) }) ?? count-1)
            if let last = intervals.last, start <= last.1 {
                if samples[max(end,last.1)].time-samples[last.0].time <= max(1,4*options.radius) {
                    intervals[intervals.count-1] = (last.0,max(end,last.1))
                } else if last.1+1 < end, last.1+1 < i {
                    intervals.append((last.1+1,end))
                }
            } else { intervals.append((start,end)) }
        }
        var result = fields
        if debug { print("PERSISTENT_LOCAL intervals=\(intervals)") }
        for interval in intervals {
            var start = interval.0, end = interval.1
            func common(_ start: Int,_ end: Int) -> Set<Int> {
                guard end > start else { return [] }
                return (start+1...end).reduce(support[start+1]) { $0.intersection(support[$1]) }
            }
            // Remove unsupported interval margins using source evidence only.
            while end-start >= 4, common(start,end).count < 12 {
                if common(start+1,end).count >= common(start,end-1).count { start += 1 }
                else { end -= 1 }
            }
            guard end-start >= 3 else { continue }
            let tracks = common(start,end).sorted().filter { j in
                let p = points[j]
                guard let anchor = PersistentSurfaceIdentity.descriptor(images[start],x: Double(p.x),y: Double(p.y)) else { return false }
                return (start+1...end).allSatisfy { i in
                    guard let d = PersistentSurfaceIdentity.descriptor(images[i],x: Double(p.x),y: Double(p.y)) else { return false }
                    return PersistentSurfaceIdentity.agrees(anchor,d)
                }
            }
            guard tracks.count >= 12 else { continue }
            if debug { print("PERSISTENT_LOCAL interval=\(start)...\(end) tracks=\(tracks.count)") }
            var basis = Array(repeating: [PersistentLightingSolver.Weight](),count: w*h)
            var compatibility = Array(repeating: 0.0,count: w*h)
            func chroma(_ pixel: Int) -> [Double] {
                let rgb = (0..<3).map { max(0.003,Double(images[start].rgb[pixel*3+$0])) }
                return [log2(rgb[0]/rgb[1]),log2(rgb[2]/rgb[1])]
            }
            for (j,track) in tracks.enumerated() {
                let p = points[track], colour = chroma(p.y*w+p.x)
                for dy in -6...6 { for dx in -6...6 {
                    let pixel = (p.y+dy)*w+p.x+dx
                    let difference = zip(colour,chroma(pixel)).reduce(0.0) { $0+pow($1.0-$1.1,2) }
                    let appearance = exp(-difference/0.09)
                    compatibility[pixel] = max(compatibility[pixel],appearance)
                    let weight = (1-Double(abs(dx))/7)*(1-Double(abs(dy))/7)*appearance
                    if weight > 1e-12 { basis[pixel].append(.init(index: j,value: weight)) }
                } }
            }
            if ProcessInfo.processInfo.environment["FRANKLUMA_PERSISTENT_BASIS_LEGACY"] == "1" {
                for pixel in basis.indices where !basis[pixel].isEmpty {
                    let scale = basis[pixel].map(\.value).max()!/basis[pixel].reduce(0) { $0+$1.value }
                    basis[pixel] = basis[pixel].map { .init(index: $0.index,value: $0.value*scale) }
                }
            } else {
                basis = PersistentLightingBasis.normalize(basis,width: w,height: h,compatibility: compatibility)
            }
            // Interior intervals return to zero; actual scene edges are free.
            // Share coefficients across quiet edges instead of allowing a
            // soft fit to redistribute a strong pulse onto quiet frames.
            var blocks = [[Int]](), block = [start]
            for i in start+1...end {
                let nearby = sourceSteps.filter { abs(samples[$0.key].time-samples[i].time) <= options.radius }.map(\.value)
                let trend = options.mode == .steady ? 0 : ExposureMath.median(nearby)
                if let source = sourceSteps[i], abs(source-trend) >= 0.08 {
                    blocks.append(block); block = [i]
                } else { block.append(i) }
            }
            blocks.append(block)
            var offsets = [Int: Int](), activeBlocks = 0
            for block in blocks {
                if (block.contains(start) && start > 0) || (block.contains(end) && end < count-1) { continue }
                for frame in block { offsets[frame] = activeBlocks*tracks.count }
                activeBlocks += 1
            }
            let frames = offsets.keys.sorted()
            guard activeBlocks > 0 else { continue }
            func weights(_ frame: Int,_ pixel: Int) -> [PersistentLightingSolver.Weight] {
                guard let offset = offsets[frame] else { return [] }
                return basis[pixel].map { .init(index: offset+$0.index,value: $0.value) }
            }
            var problemSamples = [PersistentLightingSolver.Sample]()
            // Registration uses the wide footprint, but photometry must measure
            // the same fixed material support affected by this basis function.
            // Unaffected neighbours cannot demand compensation from its centre.
            let measurements = tracks.enumerated().map { j,track in
                footprints[track].compactMap { pixel -> (Int,Double)? in
                    guard let weight = basis[pixel].first(where: { $0.index == j })?.value, weight > 1e-12 else { return nil }
                    return (pixel,weight)
                }
            }
            let levels = measurements.map { measurement in
                (start...end).map { i in log2(measurement.reduce(0) { $0+light(images[i],$1.0)*$1.1 }) }
            }
            let targets = levels.map { values in
                (start...end).map { i in
                    if options.mode == .steady { return ExposureMath.median(values) }
                    return ExposureMath.median((start...end).filter { abs(samples[$0].time-samples[i].time) <= options.radius }.map { values[$0-start] })
                }
            }
            for i in start+1...end {
                for j in tracks.indices {
                    let source = levels[j][i-start]-levels[j][i-start-1]
                    let trend = targets[j][i-start]-targets[j][i-start-1]
                    let target = (1-options.strength)*source+options.strength*trend
                    problemSamples.append(.init(before: measurements[j].map { .init(light: light(rendered[i-1],$0.0)*$0.1,weights: weights(i-1,$0.0)) },
                        after: measurements[j].map { .init(light: light(rendered[i],$0.0)*$0.1,weights: weights(i,$0.0)) },target: target))
                }
            }
            // Local fits must agree with the exposure of the entire supported
            // region, including weakly weighted footprint edges. Otherwise
            // core-patch improvements can introduce a new broad brightness step.
            if options.preserveBrightness {
                let region = basis.indices.filter { !basis[$0].isEmpty }
                let regionLevels = (start...end).map { i in log2(region.reduce(0) { $0+light(images[i],$1) }) }
                let regionTargets = (start...end).map { i -> Double in
                    if options.mode == .steady { return ExposureMath.median(regionLevels) }
                    return ExposureMath.median((start...end).filter { abs(samples[$0].time-samples[i].time) <= options.radius }.map { regionLevels[$0-start] })
                }
                for i in start+1...end {
                    let source = regionLevels[i-start]-regionLevels[i-start-1]
                    let trend = regionTargets[i-start]-regionTargets[i-start-1]
                    problemSamples.append(.init(before: region.map { .init(light: light(rendered[i-1],$0),weights: weights(i-1,$0)) },
                        after: region.map { .init(light: light(rendered[i],$0),weights: weights(i,$0)) },
                        target: (1-options.strength)*source+options.strength*trend, importance: Double(tracks.count)*4))
                }
            }
            let problem = PersistentLightingSolver.Problem(samples: problemSamples,count: activeBlocks*tracks.count,ridge: 0.05,
                limit: 0.25*options.strength*options.spatialStrength)
            guard let coefficients = PersistentLightingSolver.fit(problem) else { continue }
            let zero = Array(repeating: 0.0,count: problem.count)
            let original = problemSamples.compactMap { PersistentLightingSolver.response($0,coefficients: zero)?.error }
            let adjusted = problemSamples.compactMap { PersistentLightingSolver.response($0,coefficients: coefficients)?.error }
            if debug { print("PERSISTENT_LOCAL energy=\(original.reduce(0,{ $0+$1*$1 })) -> \(adjusted.reduce(0,{ $0+$1*$1 })) worstIncrease=\(zip(original,adjusted).map { abs($1)-abs($0) }.max() ?? 0)") }
            guard original.count == problemSamples.count, adjusted.count == original.count,
                  zip(original,adjusted).allSatisfy({ abs($1) <= abs($0)+0.02*options.strength }),
                  adjusted.reduce(0,{ $0+$1*$1 }) < original.reduce(0,{ $0+$1*$1 })*0.95 else { continue }
            for i in frames {
                let map = result[i].surface!
                var gains = map.channelEV
                for pixel in basis.indices {
                    let addition = weights(i,pixel).reduce(0) { $0+coefficients[$1.index]*$1.value }
                    for c in 0..<3 { gains[pixel*3+c] += Float(addition) }
                }
                result[i].surface = .init(width: w,height: h,channelEV: gains,guide: map.guide,rowModel: map.rowModel)
            }
        }
        return result
    }
}

/// Reproduces constant gain on compatible interiors. Appearance confidence stays
/// separate from interpolation, so normalizing a tiny donor cannot create full
/// gain on an unrelated material. The source-fixed union has one outer taper.
enum PersistentLightingBasis {
    static func normalize(_ raw: [[PersistentLightingSolver.Weight]], width: Int, height: Int,
                          compatibility: [Double]) -> [[PersistentLightingSolver.Weight]] {
        guard width > 0, height > 0, raw.count == width*height,
              compatibility.count == raw.count else { return raw }
        var distance = Array(repeating: Int.max,count: raw.count)
        var queue = [Int]()
        for p in raw.indices {
            let x = p%width, y = p/width
            if raw[p].isEmpty { distance[p] = 0; queue.append(p) }
            else if x == 0 || y == 0 || x == width-1 || y == height-1 {
                distance[p] = 1; queue.append(p)
            }
        }
        var cursor = 0
        while cursor < queue.count {
            let p = queue[cursor]; cursor += 1
            let x = p%width, y = p/width
            let neighbours = [x > 0 ? p-1 : -1,x+1 < width ? p+1 : -1,
                              y > 0 ? p-width : -1,y+1 < height ? p+width : -1]
            for n in neighbours where n >= 0 {
                if distance[n] > distance[p]+1 {
                    distance[n] = distance[p]+1; queue.append(n)
                }
            }
        }
        return raw.indices.map { p in
            let total = raw[p].reduce(0) { $0+$1.value }
            guard total.isFinite, total > 0, compatibility[p].isFinite else { return [] }
            // Three thumbnail pixels taper only the true outer support boundary.
            let taper = min(1,Double(distance[p])/3)
            let confidence = min(1,max(0,compatibility[p]))
            return raw[p].map { .init(index: $0.index,value: $0.value/total*taper*confidence) }
        }
    }
}

enum PersistentLightingSolver {
    struct Weight: Codable, Sendable { let index: Int; let value: Double }
    struct Pixel: Codable, Sendable { let light: Double; let weights: [Weight] }
    struct Sample: Codable, Sendable {
        let before: [Pixel]
        let after: [Pixel]
        let target: Double
        var importance: Double? = nil
    }
    struct Problem: Codable, Sendable {
        let samples: [Sample]
        let count: Int
        let ridge: Double
        let limit: Double
    }

    static func response(_ sample: Sample, coefficients: [Double]) -> (error: Double, jacobian: [Int: Double])? {
        func evaluate(_ pixels: [Pixel]) -> (Double, [Int: Double])? {
            var sum = 0.0, derivative = [Int: Double]()
            for pixel in pixels {
                guard pixel.light.isFinite, pixel.light >= 0 else { return nil }
                var gain = 0.0
                for weight in pixel.weights {
                    guard coefficients.indices.contains(weight.index), weight.value.isFinite,
                          weight.value >= 0 else { return nil }
                    gain += coefficients[weight.index]*weight.value
                }
                let value = pixel.light*exp2(gain)
                guard value.isFinite else { return nil }
                sum += value
                for weight in pixel.weights { derivative[weight.index, default: 0] += value*weight.value }
            }
            guard sum.isFinite, sum > 0 else { return nil }
            return (sum, derivative.mapValues { $0/sum })
        }
        guard sample.target.isFinite, let before = evaluate(sample.before), let after = evaluate(sample.after) else { return nil }
        var jacobian = after.1
        for (index,value) in before.1 { jacobian[index, default: 0] -= value }
        return (log2(after.0/before.0)-sample.target, jacobian.filter { abs($0.value) > 1e-12 })
    }

    /// Matrix-free normal-equation solve avoids a dense matrix per frame/track.
    static func fit(_ problem: Problem) -> [Double]? {
        guard problem.count > 0, problem.ridge.isFinite, problem.ridge > 0,
              problem.limit.isFinite, problem.limit >= 0, !problem.samples.isEmpty else { return nil }
        var coefficients = [Double](repeating: 0, count: problem.count)
        if problem.limit == 0 { return coefficients }
        func dot(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).reduce(0) { $0+$1.0*$1.1 } }
        for _ in 0..<5 {
            if Task.isCancelled { return nil }
            var rows = [(error: Double, jacobian: [Int: Double])]()
            for sample in problem.samples {
                guard let row = response(sample, coefficients: coefficients) else { return nil }
                let importance = sample.importance ?? 1
                guard importance.isFinite, importance > 0 else { return nil }
                let scale = sqrt(importance)
                rows.append((row.error*scale,row.jacobian.mapValues { $0*scale }))
            }
            var rhs = coefficients.map { -problem.ridge*$0 }
            for row in rows { for (index,value) in row.jacobian { rhs[index] -= value*row.error } }
            func multiply(_ vector: [Double]) -> [Double] {
                var result = vector.map { problem.ridge*$0 }
                for row in rows {
                    let projected = row.jacobian.reduce(0.0) { $0+vector[$1.key]*$1.value }
                    for (index,value) in row.jacobian { result[index] += projected*value }
                }
                return result
            }
            var delta = [Double](repeating: 0,count: problem.count), residual = rhs, direction = rhs
            var power = dot(residual,residual)
            let tolerance = max(1e-24,power*1e-20)
            for _ in 0..<min(512,problem.count*2) {
                if power <= tolerance { break }
                let product = multiply(direction), denominator = dot(direction,product)
                guard denominator.isFinite, denominator > 0 else { return nil }
                let alpha = power/denominator
                for i in delta.indices { delta[i] += alpha*direction[i]; residual[i] -= alpha*product[i] }
                let next = dot(residual,residual), beta = next/power
                for i in direction.indices { direction[i] = residual[i]+beta*direction[i] }
                power = next
            }
            for i in coefficients.indices { coefficients[i] = max(-problem.limit,min(problem.limit,coefficients[i]+delta[i])) }
            guard coefficients.allSatisfy(\.isFinite) else { return nil }
        }
        return coefficients
    }
}

enum PersistentSurfaceIdentity {
    static func descriptor(_ image: SpatialThumbnail, x: Double, y: Double, half: Int = 6) -> [Double]? {
        let ix = Int(floor(x)), iy = Int(floor(y)), fx = x-Double(ix), fy = y-Double(iy)
        guard half >= 1, ix >= half, iy >= half, ix+half+1 < image.width, iy+half+1 < image.height else { return nil }
        let side = 2*half+1
        let squaredAxis = Double(side)*Double(half*(half+1)*(2*half+1))/3
        var channels = Array(repeating: [Double](), count: 3)
        for dy in -half...half { for dx in -half...half { for c in 0..<3 {
            let p = ((iy+dy)*image.width+ix+dx)*3+c
            let top = Double(image.rgb[p])*(1-fx)+Double(image.rgb[p+3])*fx
            let bottom = Double(image.rgb[p+image.width*3])*(1-fx)+Double(image.rgb[p+image.width*3+3])*fx
            channels[c].append(log2(max(0.001, top*(1-fy)+bottom*fy)))
        } } }
        var values = [Double]()
        for channel in channels {
            let mean = channel.reduce(0,+)/Double(side*side)
            var sx = 0.0, sy = 0.0
            for dy in -half...half { for dx in -half...half {
                let value = channel[(dy+half)*side+dx+half]-mean
                sx += value*Double(dx)/squaredAxis; sy += value*Double(dy)/squaredAxis
            } }
            for dy in -half...half { for dx in -half...half {
                values.append(channel[(dy+half)*side+dx+half]-mean-sx*Double(dx)-sy*Double(dy))
            } }
        }
        let norm = sqrt(values.reduce(0) { $0+$1*$1 })
        // A flat or planar patch supplies no identity after removing lighting.
        guard norm.isFinite, norm/sqrt(Double(values.count)) > 0.003 else { return nil }
        return values.map { $0/norm }
    }

    static func agrees(_ a: [Double], _ b: [Double]) -> Bool {
        a.count == b.count && !a.isEmpty && zip(a,b).reduce(0) { $0+$1.0*$1.1 } > 0.95
    }

    struct Point: Hashable { let x: Double; let y: Double }
    struct Episode { let anchor: [Double]; let edges: Int }
}

enum SharedFlashAnchor {
    struct Observation {
        let x: Double
        let source: Double
        let rendered: Double
        var material: String = "all"
    }

    static func adjustments(count: Int, residuals: [Int: Double], amount: Double) -> [Double] {
        guard count > 1, amount > 0, !residuals.isEmpty else { return Array(repeating: 0, count: count) }
        let cuts = residuals.keys.filter { $0 > 0 && $0 < count }.sorted()
        guard !cuts.isEmpty else { return Array(repeating: 0, count: count) }
        let boundaries = [0] + cuts + [count]
        let n = boundaries.count-1
        var diagonal = (0..<n).map { Double(boundaries[$0+1]-boundaries[$0]) }
        var lower = Array(repeating: 0.0, count: n), rhs = lower
        for i in 1..<n {
            let weight = 4.0, residual = residuals[boundaries[i]]! * amount
            diagonal[i-1] += weight; diagonal[i] += weight; lower[i] = -weight
            rhs[i-1] += weight*residual; rhs[i] -= weight*residual
        }
        for i in 1..<n {
            let factor = lower[i]/diagonal[i-1]
            diagonal[i] -= factor*lower[i]; rhs[i] -= factor*rhs[i-1]
        }
        var values = rhs
        for i in stride(from: n-1, through: 0, by: -1) {
            values[i] = (rhs[i]-(i+1 < n ? lower[i+1]*values[i+1] : 0))/diagonal[i]
        }
        var result = Array(repeating: 0.0, count: count)
        for i in 0..<n { for frame in boundaries[i]..<boundaries[i+1] { result[frame] = values[i] } }
        let centre = ExposureMath.median(result), limit = 0.25*amount
        // Tiny offsets can cross 8-bit shadow quantization thresholds without
        // resolving a visible shared flash. Soft thresholding is continuous
        // and remains homogeneous in the user's correction amount.
        let deadband = 0.01*amount
        return result.map {
            let value = $0-centre
            let reduced = max(0, abs(value)-deadband)*(value < 0 ? -1 : 1)
            return max(-limit, min(limit, reduced))
        }
    }

    static func residual(_ observations: [Observation], width: Int, trend: Double, amount: Double) -> Double? {
        guard observations.count >= 12, amount > 0 else { return nil }
        let source = ExposureMath.median(observations.map(\.source))
        guard abs(source) >= 0.08,
              observations.filter({ $0.source*source > 0 }).count*10 >= observations.count*9 else { return nil }
        func error(_ observation: Observation) -> Double {
            let target = (1-amount)*observation.source+amount*trend
            return observation.rendered-target
        }
        let residual = ExposureMath.median(observations.map(error))
        let rendered = ExposureMath.median(observations.map(\.rendered))
        guard abs(residual) >= 0.06*amount, abs(rendered) >= 0.06*amount,
              rendered*residual > 0 else { return nil }
        for right in [false, true] {
            let group = observations.filter { ($0.x >= Double(width)/2) == right }
            guard group.count >= 6 else { return nil }
            let values = group.map(error)
            guard values.filter({ $0*residual > 0 }).count*5 >= values.count*4,
                  ExposureMath.median(values)*residual > 0,
                  abs(ExposureMath.median(values)) >= 0.03*amount,
                  ExposureMath.median(group.map(\.rendered))*residual > 0 else { return nil }
        }
        // A large background can occupy both spatial halves. Validate smaller
        // supported material groups too, so independently lit subjects cannot
        // be overruled merely by background area.
        for group in Dictionary(grouping: observations, by: \.material).values where group.count >= 3 {
            let values = group.map(error)
            guard ExposureMath.median(values)*residual > 0,
                  abs(ExposureMath.median(values)) >= 0.015*amount,
                  ExposureMath.median(group.map(\.rendered))*residual > 0 else { return nil }
        }
        // The target already contains Strength. Normalize here because the
        // bounded solver applies Strength × Spatial once, not a second
        // correction of the variation deliberately retained by the user.
        return residual/amount
    }

    static func apply(samples: [ExposureSample], stops: [Double], fields: [SpatialField], options: SceneSettings) -> [SpatialField] {
        guard samples.count > 2, samples.count == fields.count,
              samples.allSatisfy({ $0.thumbnail != nil }), fields.allSatisfy({ $0.surface != nil }) else { return fields }
        let rendered = samples.indices.map { i -> SpatialThumbnail in
            let image = samples[i].thumbnail!, map = fields[i].surface!
            var rgb = [Float](); rgb.reserveCapacity(image.rgb.count)
            for y in 0..<image.height { for x in 0..<image.width {
                let p = (y*image.width+x)*3
                rgb += SpatialRenderer.surfaceRGB((0..<3).map { Double(image.rgb[p+$0]) },
                    x: (Double(x)+0.5)/Double(image.width), y: (Double(y)+0.5)/Double(image.height),
                    map: map, global: stops[i]+(fields[i].brightnessEV ?? 0)).map(Float.init)
            } }
            return SpatialThumbnail(width: image.width, height: image.height, rgb: rgb)
        }
        func light(_ image: SpatialThumbnail, _ x: Double, _ y: Double) -> Double? {
            let ix = Int(floor(x)), iy = Int(floor(y)), fx = x-Double(ix), fy = y-Double(iy)
            guard ix >= 6, iy >= 6, ix+7 < image.width, iy+7 < image.height else { return nil }
            var sum = 0.0
            for dy in -6...6 { for dx in -6...6 { for c in 0..<3 {
                let p = ((iy+dy)*image.width+ix+dx)*3+c
                let top = Double(image.rgb[p])*(1-fx)+Double(image.rgb[p+3])*fx
                let bottom = Double(image.rgb[p+image.width*3])*(1-fx)+Double(image.rgb[p+image.width*3+3])*fx
                sum += [0.2126,0.7152,0.0722][c]*max(0,top*(1-fy)+bottom*fy)/169
            } } }
            return sum > 0.003 && sum < 0.8 ? sum : nil
        }
        var pairs = [Int: [Observation]](), sourceSteps = [Int: Double]()
        let persistent = ProcessInfo.processInfo.environment["FRANKLUMA_PERSISTENT_FLASH_SUPPORT"] == "1"
        var episodes = [PersistentSurfaceIdentity.Point: PersistentSurfaceIdentity.Episode]()
        for i in 1..<samples.count {
            if Task.isCancelled { return fields }
            guard fields[i].surface?.rowModel != true, fields[i-1].surface?.rowModel != true else {
                episodes.removeAll(); continue
            }
            let a = samples[i-1].thumbnail!, b = samples[i].thumbnail!
            let model = SurfaceMotion.estimate(SurfaceMotion.coarse(a), SurfaceMotion.coarse(b))
                ?? SurfaceMotion.Model(x: [1,0,0], y: [0,1,0])
            var observations = [Observation]()
            var following = [PersistentSurfaceIdentity.Point: PersistentSurfaceIdentity.Episode]()
            for y in stride(from: 6, to: a.height-7, by: 8) { for x in stride(from: 6, to: a.width-7, by: 8) {
                let q = model.point(Double(x), Double(y))
                guard let first = SurfaceTracking.descriptor(a, x: x, y: y, half: 6),
                      let second = SurfaceTracking.descriptor(b, x: q.0, y: q.1, half: 6),
                      first.energy > 0.03, second.energy > 0.03 else { continue }
                let correlation = zip(first.texture, second.texture).reduce(0.0) { $0+$1.0*$1.1 }/(Double(first.texture.count)*first.energy*second.energy)
                guard correlation > 0.95, let sa = light(a, Double(x), Double(y)), let sb = light(b, q.0, q.1),
                      let ra = light(rendered[i-1], Double(x), Double(y)), let rb = light(rendered[i], q.0, q.1) else { continue }
                if persistent {
                    let sourcePoint = PersistentSurfaceIdentity.Point(x: Double(x), y: Double(y))
                    let targetPoint = PersistentSurfaceIdentity.Point(x: q.0, y: q.1)
                    guard let target = PersistentSurfaceIdentity.descriptor(b, x: q.0, y: q.1),
                          let firstIdentity = PersistentSurfaceIdentity.descriptor(a, x: Double(x), y: Double(y)) else { continue }
                    let old = episodes[sourcePoint]
                    let anchor = old?.anchor ?? firstIdentity
                    let episode: PersistentSurfaceIdentity.Episode
                    if PersistentSurfaceIdentity.agrees(anchor, target) {
                        episode = .init(anchor: anchor, edges: (old?.edges ?? 0)+1)
                    } else if PersistentSurfaceIdentity.agrees(firstIdentity, target) {
                        episode = .init(anchor: firstIdentity, edges: 1)
                    } else { continue }
                    following[targetPoint] = episode
                    guard episode.edges >= 3 else { continue }
                }
                let material = "\(Int(floor(first.mean[0]-first.mean[1]))):\(Int(floor(first.mean[2]-first.mean[1])))"
                observations.append(Observation(x: Double(x), source: log2(sb/sa), rendered: log2(rb/ra), material: material))
            } }
            episodes = following
            if observations.count >= 12 {
                pairs[i] = observations; sourceSteps[i] = ExposureMath.median(observations.map(\.source))
            }
        }
        let amount = options.strength*options.spatialStrength
        var residuals = [Int: Double]()
        for (i, observations) in pairs {
            let nearby = sourceSteps.filter { abs(samples[$0.key].time-samples[i].time) <= options.radius }.map(\.value)
            guard nearby.count >= 3 else { continue }
            let trend = options.mode == .steady ? 0 : ExposureMath.median(nearby)
            if let value = residual(observations, width: samples[i].thumbnail!.width, trend: trend, amount: options.strength) { residuals[i] = value }
        }
        let adjustment = adjustments(count: samples.count, residuals: residuals, amount: amount)
        var result = fields
        for i in result.indices { result[i].brightnessEV = (result[i].brightnessEV ?? 0)+adjustment[i] }
        return result
    }
}

/// Experimental residual calibration. Tracks are selected from source geometry;
/// rendered brightness is measured only after identity and temporal support are
/// established. Neither reference pixels nor neighbouring frames enter output.
enum TrackedSurfaceResidual {
    struct Observation {
        let frame: Int
        let x: Int
        let y: Int
        let level: Double
    }
    struct Track {
        let identity: [Double]
        var identityHalf = 2
        var observations: [Observation]
    }
    struct Measurement {
        let x: Int
        let y: Int
        let target: Double
    }
    static func rapidResidual(times: [Double], required: [Double], radius: Double, mode: NormalisationMode) -> [Double] {
        guard times.count == required.count, required.count >= 3,
              required.allSatisfy(\.isFinite) else { return Array(repeating: 0,count: required.count) }
        let baseline = mode == .steady
            ? Array(repeating: ExposureMath.median(required),count: required.count)
            : ExposureMath.smoothTargets(times: times,levels: required,radius: radius,preserveShortRamps: true)
        return zip(required,baseline).map(-)
    }
    typealias PulseFootprints = [[(x:Double,y:Double)]]
    typealias TransportedPulseHandler = ([Observation],Double,Double,PulseFootprints,[Int],[Double]?) -> Void
    /// Read-only source pulse audit. Never reads rendered fields or gains.
    static func pulseDiagnostics(samples: [ExposureSample], images: [SpatialThumbnail], tracks: [Track], endpointRadius: Int = 8, geometryHalf: Int = 2, geometryOnly: Bool = false, cameraGuided: Bool = false,cameraHalf: Int = 6,
                                 frameInterval: Int = 1, photometryHalf: Int = 2, photometryImages: [SpatialThumbnail]? = nil,stationaryCameraFrames: Set<Int> = [],quietSourceProtected: TransportedPulseHandler? = nil,lowTextureCertified: TransportedPulseHandler? = nil, transportedCertified: TransportedPulseHandler? = nil, certified: (([Observation], Double, Double) -> Void)? = nil) {
        guard (6...12).contains(cameraHalf),(1...6).contains(frameInterval),
              (2...6).contains(photometryHalf) else { return }
        let meterImages = photometryImages ?? images
        guard meterImages.count == images.count,zip(meterImages,images).allSatisfy({ $0.width == $1.width && $0.height == $1.height && $0.rgb.count == $1.rgb.count }) else { return }
        let environment = ProcessInfo.processInfo.environment
        let emitDiagnostics = certified == nil || environment["FRANKLUMA_COMMON_PULSE_DIAGNOSTICS"] == "1"
        let luminanceOnly = environment["FRANKLUMA_COMMON_PULSE_LUMINANCE"] == "1"
        let refinedSampling = cameraGuided && cameraHalf == 6 && environment["FRANKLUMA_COMMON_PULSE_REFINE_SAMPLING"] == "1"
        let cameraDonorDiameter = cameraHalf == 6 ? 13 : 2*cameraHalf+2
        let proposedTolerance = Double(environment["FRANKLUMA_COMMON_PULSE_TOLERANCE"] ?? "0.02") ?? 0.02
        let tolerance = proposedTolerance.isFinite && (0.005...0.1).contains(proposedTolerance) ? proposedTolerance : 0.02
        let proposedDonors = Int(environment["FRANKLUMA_COMMON_PULSE_DONORS"] ?? "12") ?? 12
        let minimumDonors = (4...48).contains(proposedDonors) ? proposedDonors : 12
        struct Candidate {
            let points: [Observation]
            let excursion: Double
            let heldError: Double
            var colourEvidence: CommonIlluminationComponent.ObservablePulseEvidence? = nil
        }
        struct TransportedCandidate {
            let query: Candidate
            let footprints: PulseFootprints
            let validPixels: [Int]
            var weights: [Double]? = nil
            var lowTexture: Bool = false
            var colourEvidence: CommonIlluminationComponent.ObservablePulseEvidence? = nil
        }
        var triples = [Int: [[Observation]]]()
        for track in tracks where track.observations.count >= 3 {
            for index in 1..<(track.observations.count-1) {
                let points = Array(track.observations[(index-1)...(index+1)])
                guard points[0].frame+frameInterval == points[1].frame,points[1].frame+frameInterval == points[2].frame else { continue }
                triples[points[1].frame,default: []].append(points)
            }
        }
        func pixels(_ point: Observation, half: Int = 2, coordinate: (Double,Double)? = nil) -> [Double] {
            let image = meterImages[point.frame]
            let xx = coordinate?.0 ?? Double(point.x),yy = coordinate?.1 ?? Double(point.y)
            let ix = Int(floor(xx)),iy = Int(floor(yy)),fx = xx-Double(ix),fy = yy-Double(iy)
            return (-half...half).flatMap { dy in (-half...half).flatMap { dx in
                (0..<3).map { channel in
                    let p = ((iy+dy)*image.width+ix+dx)*3+channel
                    if fx == 0 && fy == 0 { return Double(image.rgb[p]) }
                    let top = Double(image.rgb[p])*(1-fx)+Double(image.rgb[p+3])*fx
                    let bottom = Double(image.rgb[p+image.width*3])*(1-fx)+Double(image.rgb[p+image.width*3+3])*fx
                    return top*(1-fy)+bottom*fy
                }
            } }
        }
        func disjoint(_ a: Candidate,_ b: Candidate,diameter: Int) -> Bool {
            zip(a.points,b.points).allSatisfy {
                max(abs($0.x-$1.x),abs($0.y-$1.y)) >= diameter
            }
        }
        for frame in triples.keys.sorted() {
            if Task.isCancelled { return }
            let before = SurfaceTracking.Prepared(images[frame-frameInterval],half: geometryHalf),after = SurfaceTracking.Prepared(images[frame+frameInterval],half: geometryHalf)
            let flowDiagnostic = transportedCertified != nil || environment["FRANKLUMA_COMMON_PULSE_FLOW_DIAGNOSTICS"] == "1"
            let beforeFlow = flowDiagnostic ? SurfaceMotion.opticalFlow(images[frame],images[frame-frameInterval]) : nil
            let afterFlow = flowDiagnostic ? SurfaceMotion.opticalFlow(images[frame],images[frame+frameInterval]) : nil
            var transported = [TransportedCandidate]()
            var rejected = [String: Int](),candidates = [Candidate](),energies = [Double](),errors = [Double]()
            let alpha = (samples[frame].time-samples[frame-frameInterval].time)/(samples[frame+frameInterval].time-samples[frame-frameInterval].time)
            for points in triples[frame]! {
                if let descriptor = before.at(points[0].x,points[0].y) { energies.append(descriptor.energy) }
                if cameraGuided {
                    guard let a = SurfaceTracking.descriptor(images[frame-frameInterval],x:points[0].x,y:points[0].y,half:cameraHalf),
                          let c = SurfaceTracking.descriptor(images[frame+frameInterval],x:points[2].x,y:points[2].y,half:cameraHalf),
                          a.energy > 0.03,c.energy > 0.03,
                          zip(a.texture,c.texture).reduce(0,{ $0+$1.0*$1.1 })/(Double(a.texture.count)*a.energy*c.energy) > 0.95 else {
                        rejected["cameraEndpointIdentityMismatch",default:0] += 1;continue
                    }
                } else {
                guard let endpoint = SurfaceTracking.match(before,after,x: points[0].x,y: points[0].y,radius: max(1,min(64,endpointRadius)),subpixel: false) else {
                    rejected["endpointNoMatch",default: 0] += 1;continue
                }
                errors.append(endpoint.error)
                guard endpoint.x == points[2].x,endpoint.y == points[2].y else {
                    rejected["endpointDifferentPoint",default: 0] += 1;continue
                }
                guard endpoint.confidence*(geometryOnly ? 1 : endpoint.photometricConfidence) > 0.6 else {
                    rejected["endpointWeakConfidence",default: 0] += 1;continue
                }
                }
                var coordinates: [(Double,Double)?] = [nil,nil,nil]
                if refinedSampling {
                    var valid = true
                    let proposed = Double(environment["FRANKLUMA_COMMON_PULSE_REFINEMENT_IMPROVEMENT"] ?? "0.01") ?? 0.01
                    let improvement = proposed.isFinite && (0.0001...0.05).contains(proposed) ? proposed : 0.01
                    for index in [0,2] {
                        coordinates[index] = SurfaceTracking.cameraRefinedPoint(images[frame],images[points[index].frame],
                            x:Double(points[1].x),y:Double(points[1].y),referenceX:Double(points[index].x),referenceY:Double(points[index].y),minimumImprovement:improvement,
                            diagnostic:environment["FRANKLUMA_COMMON_PULSE_REFINEMENT_TRACE"] == "1" ? { stage,values in
                                var record: [String:Any] = values
                                record["stage"] = stage;record["middleFrame"] = frame;record["sceneStart"] = samples[0].time
                                record["referenceFrame"] = points[index].frame;record["queryX"] = points[1].x;record["queryY"] = points[1].y
                                if let data = try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),
                                   let json = String(data:data,encoding:.utf8) { print("COMMON_LIGHT_GEOMETRY_REFINEMENT",json) }
                            } : nil)
                        if coordinates[index] == nil { valid = false }
                    }
                    guard valid else { rejected["refinedGeometryUnsupported",default:0] += 1;continue }
                }
                guard points.enumerated().allSatisfy({ index,point in
                    let image = images[point.frame],xx = coordinates[index]?.0 ?? Double(point.x),yy = coordinates[index]?.1 ?? Double(point.y)
                    let extra = coordinates[index] == nil ? 0 : 1
                    return Int(floor(xx))-photometryHalf >= 0 && Int(floor(yy))-photometryHalf >= 0 &&
                        Int(floor(xx))+photometryHalf+extra < image.width && Int(floor(yy))+photometryHalf+extra < image.height
                }) else { rejected["photometryOutsideImage",default:0] += 1;continue }
                let a = pixels(points[0],half:photometryHalf,coordinate:coordinates[0]),b = pixels(points[1],half:photometryHalf),c = pixels(points[2],half:photometryHalf,coordinate:coordinates[2])
                let evidence = luminanceOnly
                    ? CommonIlluminationComponent.pulseLuminancePixels(before: a,middle: b,after: c,alpha: alpha,tolerance: tolerance,side:2*photometryHalf+1)
                    : CommonIlluminationComponent.pulsePixels(before: a,middle: b,after: c,alpha: alpha,tolerance: tolerance,side:2*photometryHalf+1)
                if let protect = quietSourceProtected,!refinedSampling,photometryImages == nil,photometryHalf == 2 {
                    // Use direct RGB evidence, not quiet aggregate luminance:
                    // opposing channel changes or changed material must not
                    // establish protection. Coordinates are the exact source
                    // samples checked above; fractional refinements need their
                    // own explicit footprint contract before this path applies.
                    let quiet = CommonIlluminationComponent.pulsePixels(before:a,middle:b,after:c,alpha:alpha,tolerance:0.0025)
                    if quiet.rejection == nil,quiet.channelExcursion.count == 3,
                       quiet.channelExcursion.map({ abs($0) }).max()!+2*quiet.heldError <= 0.005 {
                        let footprints = points.map { point in
                            (-2...2).flatMap { dy in (-2...2).map { dx in (x:Double(point.x+dx),y:Double(point.y+dy)) } }
                        }
                        protect(points,0,quiet.heldError,footprints,Array(0..<25),nil)
                    }
                }
                if let reason = evidence.rejection {
                    rejected[reason,default: 0] += 1
                    if flowDiagnostic {
                        var record: [String:Any] = ["sceneStart":samples[0].time,"middleFrame":frame,
                            "x":points[1].x,"y":points[1].y,"constantRejection":reason]
                        let kernelMeter = environment["FRANKLUMA_COMMON_PULSE_KERNEL_METER"] == "1" && photometryImages == nil
                        let transportedHalves = kernelMeter ? [photometryHalf,5] : (environment["FRANKLUMA_COMMON_PULSE_SMALL_FOOTPRINT"] == "1" ? [photometryHalf,1] : [photometryHalf])
                        for transportedHalf in transportedHalves {
                        if let beforeFlow,let afterFlow,
                           let transportedBefore = SurfaceTracking.flowTransportedPixels(images[frame],images[frame-frameInterval],flow:beforeFlow,x:points[1].x,y:points[1].y,half:transportedHalf,geometryHalf:cameraHalf,measurementReference:meterImages[frame-frameInterval]),
                           let transportedAfter = SurfaceTracking.flowTransportedPixels(images[frame],images[frame+frameInterval],flow:afterFlow,x:points[1].x,y:points[1].y,half:transportedHalf,geometryHalf:cameraHalf,measurementReference:meterImages[frame+frameInterval]) {
                            if kernelMeter && transportedHalf == 5 {
                                let middlePoints = (-5...5).flatMap { dy in (-5...5).map { dx in (x:Double(points[1].x+dx),y:Double(points[1].y+dy)) } }
                                let rawFootprints = [transportedBefore.points,middlePoints,transportedAfter.points]
                                let kernel = CommonIlluminationComponent.pulseKernelLuminancePixels(before:transportedBefore.pixels,
                                    middle:pixels(points[1],half:5),after:transportedAfter.pixels,footprints:rawFootprints,
                                    width:images[frame].width,height:images[frame].height,alpha:alpha,tolerance:tolerance)
                                record["meter"] = "finiteKernelWithDisjointSourceSupports"
                                record["heldError"] = kernel.heldError
                                if let rejection = kernel.rejection { record["rejection"] = rejection }
                                if let excursion = kernel.excursion {
                                    record.removeValue(forKey:"rejection");record["excursion"] = excursion
                                    transported.append(.init(query:.init(points:points,excursion:excursion,heldError:kernel.heldError),
                                        footprints:rawFootprints.map { footprint in kernel.tapIndices.map { footprint[$0] } },
                                        validPixels:kernel.validTapIndices,weights:kernel.tapWeights))
                                    break
                                }
                                continue
                            }
                            let evidence = CommonIlluminationComponent.pulseMaskedLuminancePixels(before:transportedBefore.pixels,middle:pixels(points[1],half:transportedHalf),after:transportedAfter.pixels,alpha:alpha,tolerance:tolerance,side:2*transportedHalf+1)
                            if environment["FRANKLUMA_COMMON_PULSE_SPECTRAL_DIAGNOSTICS"] == "1" {
                                let spectral = CommonIlluminationComponent.pulseSpectralLuminancePixels(before:transportedBefore.pixels,
                                    middle:pixels(points[1],half:transportedHalf),after:transportedAfter.pixels,alpha:alpha,tolerance:tolerance,side:2*transportedHalf+1,rankAware:environment["FRANKLUMA_COMMON_PULSE_RANK_AWARE_SPECTRAL"] == "1")
                                var diagnostic: [String:Any] = ["sceneStart":samples[0].time,"middleFrame":frame,"x":points[1].x,"y":points[1].y,"side":2*transportedHalf+1,"heldError":spectral.heldError]
                                if let gains = spectral.gains { diagnostic["gains"] = gains }
                                if let excursion = spectral.representativeExcursion { diagnostic["excursion"] = excursion;diagnostic["pixelExcursion"] = spectral.pixelExcursion }
                                diagnostic["identifiableRank"] = spectral.identifiableRank
                                diagnostic["maximumPredictionUncertaintyEV"] = spectral.maximumPredictionUncertaintyEV
                                if let rejection = spectral.rejection { diagnostic["rejection"] = rejection }
                                if emitDiagnostics,let data = try? JSONSerialization.data(withJSONObject:diagnostic,options:[.sortedKeys]),let json = String(data:data,encoding:.utf8) { print("COMMON_LIGHT_SOURCE_SPECTRAL_FLOW",json) }
                            }
                            record["photometrySide"] = 2*transportedHalf+1
                            record["heldError"] = evidence.heldError;record["validPixels"] = evidence.validPixels
                            record["maximumDisplacement"] = max(transportedBefore.maximumDisplacement,transportedAfter.maximumDisplacement)
                            if let rejection = evidence.rejection { record["rejection"] = rejection }
                            if let excursion = evidence.excursion {
                                record.removeValue(forKey:"rejection")
                                record["excursion"] = excursion
                                let middlePoints = (-transportedHalf...transportedHalf).flatMap { dy in
                                    (-transportedHalf...transportedHalf).map { dx in (x:Double(points[1].x+dx),y:Double(points[1].y+dy)) }
                                }
                                transported.append(.init(query:.init(points:points,excursion:excursion,heldError:evidence.heldError),
                                    footprints:[transportedBefore.points,middlePoints,transportedAfter.points],validPixels:evidence.validPixels))
                                break
                            }
                        } else { record["rejection"] = "unsupportedFlowGeometry" }
                        }
                        if emitDiagnostics,let data = try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),
                           let json = String(data:data,encoding:.utf8) { print("COMMON_LIGHT_SOURCE_FLOW",json) }
                    }
                    if environment["FRANKLUMA_COMMON_PULSE_MASKED_DIAGNOSTICS"] == "1" {
                        let masked = CommonIlluminationComponent.pulseMaskedLuminancePixels(before:a,middle:b,after:c,alpha:alpha,tolerance:tolerance,side:2*photometryHalf+1)
                        var record: [String:Any] = ["sceneStart":samples[0].time,"middleFrame":frame,
                            "x":points[1].x,"y":points[1].y,"constantRejection":reason,"heldError":masked.heldError,
                            "validPixels":masked.validPixels,"side":2*photometryHalf+1]
                        if let rejection = masked.rejection { record["rejection"] = rejection }
                        if let excursion = masked.excursion { record["excursion"] = excursion }
                        if let data = try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),
                           let json = String(data:data,encoding:.utf8) { print("COMMON_LIGHT_SOURCE_MASKED",json) }
                    }
                    if environment["FRANKLUMA_COMMON_PULSE_LINEAR_DIAGNOSTICS"] == "1" {
                        let linear = CommonIlluminationComponent.pulseLinearLuminancePixels(before:a,middle:b,after:c,alpha:alpha,tolerance:tolerance)
                        var record: [String:Any] = ["sceneStart":samples[0].time,"middleFrame":frame,
                            "x":points[1].x,"y":points[1].y,"constantRejection":reason,"heldError":linear.heldError]
                        if let rejection = linear.rejection { record["rejection"] = rejection }
                        else {
                            record["gain"] = linear.gain;record["linearOffset"] = linear.offset
                            record["pixelExcursion"] = linear.pixelExcursion;record["representativeExcursion"] = linear.representativeExcursion
                        }
                        if let data = try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),
                           let json = String(data:data,encoding:.utf8) { print("COMMON_LIGHT_SOURCE_LINEAR",json) }
                    }
                    if environment["FRANKLUMA_COMMON_PULSE_OBSERVABLE_RGB_DIAGNOSTICS"] == "1" {
                        let observed = CommonIlluminationComponent.pulseObservableRGB(before:a,middle:b,after:c,alpha:alpha,tolerance:tolerance)
                        var record: [String:Any] = ["sceneStart":samples[0].time,"middleFrame":frame,
                            "x":points[1].x,"y":points[1].y,"constantRejection":reason,
                            "measuredLuminanceCoverage":observed.minimumMeasuredLuminanceCoverage,"heldError":observed.heldError]
                        if let rejection = observed.rejection { record["rejection"] = rejection }
                        else {
                            record["channelExcursion"] = observed.channelExcursion.map { $0.map { $0 as Any } ?? NSNull() }
                            record["representativeExcursion"] = observed.representativeExcursion
                        }
                        if let data = try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),
                           let json = String(data:data,encoding:.utf8) { print("COMMON_LIGHT_OBSERVABLE_RGB",json) }
                    }
                    if environment["FRANKLUMA_COMMON_PULSE_PLANE_DIAGNOSTICS"] == "1" {
                        let plane = CommonIlluminationComponent.pulsePlaneLuminancePixels(before:a,middle:b,after:c,alpha:alpha,tolerance:tolerance)
                        var record: [String: Any] = ["sceneStart":samples[0].time,"middleFrame":frame,
                            "x":points[1].x,"y":points[1].y,"constantRejection":reason,
                            "heldError":plane.heldError,"predictionDisagreement":plane.predictionDisagreement]
                        if let rejection = plane.rejection { record["rejection"] = rejection }
                        else { record["coefficients"] = plane.coefficients;record["pixelExcursion"] = plane.pixelExcursion }
                        if let data = try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),
                           let json = String(data:data,encoding:.utf8) { print("COMMON_LIGHT_SOURCE_PLANE",json) }
                    }
                    if environment["FRANKLUMA_COMMON_PULSE_TONE_DIAGNOSTICS"] == "1" {
                        let half = max(2,min(6,Int(environment["FRANKLUMA_COMMON_PULSE_TONE_HALF"] ?? "2") ?? 2))
                        guard points.allSatisfy({ $0.x >= half && $0.y >= half && $0.x+half < images[$0.frame].width && $0.y+half < images[$0.frame].height }) else {
                            rejected["toneFootprintOutsideImage",default:0] += 1;continue
                        }
                        let overlapOnly = environment["FRANKLUMA_COMMON_PULSE_TONE_OVERLAP"] == "1"
                        let tone = CommonIlluminationComponent.pulseToneLuminancePixels(before:pixels(points[0],half:half,coordinate:coordinates[0]),middle:pixels(points[1],half:half),after:pixels(points[2],half:half,coordinate:coordinates[2]),alpha:alpha,tolerance:tolerance,side:2*half+1,overlapOnly:overlapOnly)
                        var record: [String: Any] = ["sceneStart":samples[0].time,"middleFrame":frame,
                            "x":points[1].x,"y":points[1].y,"constantRejection":reason,
                            "side":2*half+1,"overlapOnly":overlapOnly,"heldError":tone.heldError,"predictionDisagreement":tone.predictionDisagreement]
                        if let rejection = tone.rejection { record["rejection"] = rejection }
                        else {
                            record["slope"] = tone.slope;record["intercept"] = tone.intercept
                            record["representativeExcursion"] = tone.representativeExcursion
                            record["pixelExcursion"] = tone.pixelExcursion
                        }
                        if let data = try? JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]),
                           let json = String(data:data,encoding:.utf8) { print("COMMON_LIGHT_SOURCE_TONE",json) }
                    }
                    continue
                }
                var middleY = 0.0,withoutPulseY = 0.0
                for pixel in 0..<((2*photometryHalf+1)*(2*photometryHalf+1)) { for channel in 0..<3 {
                    let weight = [0.2126,0.7152,0.0722][channel]
                    middleY += weight*b[pixel*3+channel]
                    withoutPulseY += weight*b[pixel*3+channel]*pow(2,-evidence.channelExcursion[channel])
                } }
                let excursion = log2(middleY/withoutPulseY)
                let colourEvidence = environment["FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_COLOUR_CLOCK"] == "1" && photometryHalf == 2
                    ? CommonIlluminationComponent.pulseObservableRGB(before:a,middle:b,after:c,alpha:alpha,tolerance:tolerance) : nil
                candidates.append(.init(points: points,excursion: excursion,heldError: evidence.heldError,colourEvidence:colourEvidence))
            }
            candidates.sort {
                let a = $0.points[1],b = $1.points[1]
                return a.x == b.x ? a.y < b.y : a.x < b.x
            }
            if cameraGuided,stationaryCameraFrames.contains(frame),photometryImages == nil,
               (environment["FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_QUERIES"] == "1" || quietSourceProtected != nil) {
                let image = images[frame]
                let requireColourClock = environment["FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_COLOUR_CLOCK"] == "1"
                for y in stride(from:6,to:image.height-6,by:6) { for x in stride(from:6,to:image.width-6,by:6) {
                    let points = [frame-frameInterval,frame,frame+frameInterval].map { Observation(frame:$0,x:x,y:y,level:0) }
                    let observed = CommonIlluminationComponent.pulseLowTextureLuminancePixels(before:pixels(points[0],half:6),
                        middle:pixels(points[1],half:6),after:pixels(points[2],half:6),alpha:alpha,tolerance:tolerance,stationaryCameraSupported:true,allowColourChange:requireColourClock)
                    guard let excursion = observed.excursion else { continue }
                    let footprint = (-2...2).flatMap { dy in (-2...2).map { dx in (x:Double(x+dx),y:Double(y+dy)) } }
                    if let protect = quietSourceProtected {
                        // A quiet-region guard is source evidence only. It does
                        // not require an event clock, become a donor, or grant
                        // permission to change a node. Keep the stricter colour
                        // check even when event queries enable RGB clocks.
                        let quietEvidence = requireColourClock
                            ? CommonIlluminationComponent.pulseLowTextureLuminancePixels(before:pixels(points[0],half:6),middle:pixels(points[1],half:6),after:pixels(points[2],half:6),alpha:alpha,tolerance:tolerance,stationaryCameraSupported:true)
                            : observed
                        if let quiet = quietEvidence.excursion,abs(quiet)+2*quietEvidence.heldError <= 0.005 {
                            protect(points,quiet,quietEvidence.heldError,[footprint,footprint,footprint],quietEvidence.validPixels,nil)
                        }
                    }
                    guard environment["FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_QUERIES"] == "1" else { continue }
                    let colour = requireColourClock ? CommonIlluminationComponent.pulseObservableRGB(before:pixels(points[0]),middle:pixels(points[1]),after:pixels(points[2]),alpha:alpha,tolerance:tolerance) : nil
                    if requireColourClock && colour?.rejection != nil { continue }
                    transported.append(.init(query:.init(points:points,excursion:excursion,heldError:observed.heldError),
                        footprints:[footprint,footprint,footprint],validPixels:observed.validPixels,weights:nil,lowTexture:true,colourEvidence:colour))
                } }
            }
            var maximumDonors = 0,maximumSmallFootprints = 0,eventQueries = 0,absenceQueries = 0,responseQueries = 0
            var eventPoints = [[String: Any]](),quietPoints = [[String: Any]](),queryPoints = [[String: Any]]()
            for query in candidates {
                func bank(_ diameter: Int) -> [Candidate] {
                    var chosen = [Candidate]()
                    for donor in candidates where disjoint(donor,query,diameter: diameter) {
                        if chosen.allSatisfy({ disjoint(donor,$0,diameter: diameter) }) { chosen.append(donor) }
                    }
                    return chosen
                }
                // Conservatively group the widest matcher/identity support.
                let donorDiameter = max(2*photometryHalf+1,cameraGuided ? cameraDonorDiameter+(refinedSampling ? 2 : 0) : 13)
                let donors = bank(donorDiameter)
                maximumDonors = max(maximumDonors,donors.count)
                if emitDiagnostics { maximumSmallFootprints = max(maximumSmallFootprints,bank(5).count) }
                if emitDiagnostics,donors.count < minimumDonors {
                    queryPoints.append(["x":query.points[1].x,"y":query.points[1].y,"excursion":query.excursion,
                        "heldError":query.heldError,"donors":donors.count,"clockState":"insufficientDonors"])
                }
                guard donors.count >= minimumDonors else { continue }
                let clock = CommonIlluminationComponent.pulseClock(excursions:donors.map(\.excursion),errors:donors.map(\.heldError),minimumDonors:minimumDonors)
                if emitDiagnostics {
                    var point: [String:Any] = ["x":query.points[1].x,"y":query.points[1].y,"excursion":query.excursion,
                        "heldError":query.heldError,"donors":donors.count,"clockState":String(describing:clock.state)]
                    if let excursion = clock.excursion { point["donorEvent"] = excursion }
                    queryPoints.append(point)
                }
                if clock.state == .quiet,let excursion = clock.excursion {
                    // A quiet external clock cannot establish the cause of a
                    // strong change in this query (for example, a moving surface
                    // changing its shading). Certify only a quiet query here.
                    guard abs(query.excursion)+2*query.heldError <= 0.01 else { continue }
                    certified?(query.points,query.excursion,query.heldError)
                    quietPoints.append(["x":query.points[1].x,"y":query.points[1].y,
                        "donorExcursion":excursion,"uncertainty":clock.uncertainty,"donors":donors.count])
                }
                guard clock.state == .event,let event = clock.excursion else { continue }
                eventQueries += 1
                let absent = max(abs(query.excursion),query.heldError) < 0.01
                let response = query.excursion*event > 0 && abs(query.excursion) > max(0.03,2*query.heldError)
                absenceQueries += absent ? 1 : 0;responseQueries += response ? 1 : 0
                if absent || response { certified?(query.points,query.excursion,query.heldError) }
                eventPoints.append(["x":query.points[1].x,"y":query.points[1].y,"excursion":query.excursion,
                    "heldError":query.heldError,"donorEvent":event,"donors":donors.count,
                    "state":absent ? "absenceCandidate" : response ? "responseCandidate" : "unknown"])
            }
            var transportedAccepted = 0,kernelAccepted = 0,lowTextureAccepted = 0
            for item in transported {
                let query = item.query
                // Transported queries never become donors. Widen exclusion for
                // the bounded search on both query and donor support.
                let diameter = max(2*photometryHalf+1,cameraGuided ? cameraDonorDiameter : 13)+4
                var donors = [Candidate]()
                for donor in candidates where disjoint(donor,query,diameter:diameter) {
                    if donors.allSatisfy({ disjoint(donor,$0,diameter:diameter) }) { donors.append(donor) }
                }
                guard donors.count >= minimumDonors else { continue }
                let clock = CommonIlluminationComponent.pulseClock(excursions:donors.map(\.excursion),errors:donors.map(\.heldError),minimumDonors:minimumDonors)
                let quiet = clock.state == .quiet && abs(query.excursion)+2*query.heldError <= 0.01
                let event = clock.state == .event && clock.excursion.map {
                    max(abs(query.excursion),query.heldError) < 0.01 ||
                    (query.excursion*$0 > 0 && abs(query.excursion) > max(0.03,2*query.heldError))
                } == true
                guard quiet || event else { continue }
                if item.lowTexture,environment["FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_COLOUR_CLOCK"] == "1" {
                    guard let colour = item.colourEvidence,
                          CommonIlluminationComponent.pulseColourCorroborates(query:colour,donors:donors.compactMap(\.colourEvidence),minimumDonors:minimumDonors,tolerance:tolerance) else { continue }
                }
                transportedAccepted += 1
                if item.weights != nil { kernelAccepted += 1 }
                if item.lowTexture { lowTextureAccepted += 1;lowTextureCertified?(query.points,query.excursion,query.heldError,item.footprints,item.validPixels,item.weights) }
                else { transportedCertified?(query.points,query.excursion,query.heldError,item.footprints,item.validPixels,item.weights) }
            }
            if transportedCertified != nil || lowTextureCertified != nil {
                print("COMMON_LIGHT_TRANSPORTED_SUPPORT","sceneStart",samples[0].time,"middleFrame",frame,
                      "frameInterval",frameInterval,"qualified",transported.count,"corroborated",transportedAccepted,
                      "kernelQualified",transported.filter { $0.weights != nil }.count,"kernelCorroborated",kernelAccepted,
                      "lowTextureQualified",transported.filter { $0.lowTexture }.count,"lowTextureCorroborated",lowTextureAccepted)
            }
            let record: [String: Any] = ["sceneStart":samples[0].time,"middleFrame":frame,"frameInterval":frameInterval,
                "tolerance":tolerance,"minimumDonors":minimumDonors,"luminanceOnly":luminanceOnly,"endpointRadius":max(1,min(64,endpointRadius)),"geometryHalf":geometryHalf,"photometryHalf":photometryHalf,"geometryOnly":geometryOnly,"cameraGuided":cameraGuided,
                "triples":triples[frame]!.count,"pixelQualified":candidates.count,"rejections":rejected,
                "maximumIndependentDonors13":maximumDonors,"hypotheticalMaximumDonors5":maximumSmallFootprints,
                "eventQueries":eventQueries,"absenceQueries":absenceQueries,"responseQueries":responseQueries,
                "medianEndpointError":ExposureMath.median(errors),"medianMatcherEnergy":ExposureMath.median(energies),
                "eventPoints":eventPoints,"quietQueries":quietPoints.count,"quietPoints":quietPoints,"queryPoints":queryPoints,
                "refinedSampling":refinedSampling,"refinementGeometrySupported":cameraHalf == 6,
                "cameraHalf":cameraHalf,"donorFootprintDiameter":cameraGuided ? cameraDonorDiameter+(refinedSampling ? 2 : 0) : 13]
            if emitDiagnostics,
               let data = try? JSONSerialization.data(withJSONObject: record,options: [.sortedKeys]),
               let json = String(data:data,encoding:.utf8) { print("COMMON_LIGHT_SOURCE_PULSE",json) }
        }
    }
    /// Experimental stationary-surface pulse composition. Unknown source rows
    /// remain unknown and every field is checked through the actual renderer.
    static func applyPulseComposition(samples: [ExposureSample], stops: [Double],
                                      fields: [SpatialField], options: SceneSettings,
                                      maximumPasses: Int? = nil, anchorBoundaries: Bool? = nil,
                                      multiInterval: Bool? = nil, supplemental: Bool? = nil,transportedMeasurements: Bool? = nil) -> [SpatialField] {
        guard samples.count >= 3, stops.count == samples.count, fields.count == samples.count,
              options.strength > 0, options.spatialStrength > 0, options.reference == nil,
              samples.allSatisfy({ $0.thumbnail != nil }) else { return fields }
        let useDetail = samples.allSatisfy { $0.detailThumbnail != nil }
        let images = samples.map { useDetail ? $0.detailThumbnail! : $0.thumbnail! }, w = images[0].width, h = images[0].height
        let meterImages: [SpatialThumbnail]? = useDetail && ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_ANALYSIS_PREFILTER"] == "1" && samples.allSatisfy({ $0.meterThumbnail != nil }) ? samples.map { $0.meterThumbnail! } : nil
        let scale = useDetail ? 2 : 1, half = 6*scale, margin = 7*scale
        guard w >= 28, h >= 28, images.allSatisfy({ $0.width == w && $0.height == h }),
              fields.allSatisfy({ $0.surface != nil && $0.surface?.rowModel != true }) else { return fields }
        let n = images.count, times = samples.map(\.time)
        let anchorEndpoints = anchorBoundaries ?? (ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_BOUNDARY_ANCHORS"] == "1")
        let neutralGains = [Float](repeating:0,count:w*h*3)
        let multiscale = multiInterval ?? (ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_MULTISCALE"] == "1")
        let supplement = multiscale && (supplemental ?? (ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_SUPPLEMENT"] == "1"))
        let uncertaintyBounded = supplement && ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_UNCERTAINTY"] == "1"
        let rendererFit = ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_RENDERER_FIT"] == "1"
        let boundedFit = rendererFit && ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_BOUNDED_FIT"] == "1"
        let backtrack = boundedFit && ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_BACKTRACK"] == "1"
        let significance = ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_SIGNIFICANCE"] == "1"
        let jointIntervals = supplement && ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_JOINT_INTERVALS"] == "1"
        let denseMeasurements = supplement && boundedFit && (transportedMeasurements ?? (ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_DENSE"] == "1"))
        let intervals = (multiscale ? [1,2] : [1]).filter { n > 2*$0 }
        var tracksByInterval = [Int:[Track]]()
        var stationaryFramesByInterval = [Int:Set<Int>]()
        // Stationary identity is independently supported across the image;
        // individual moving/occluded surfaces are excluded from this path.
        for interval in intervals { for i in interval..<n-interval {
            guard samples[i-interval...i+interval].allSatisfy({ $0.segment == samples[i].segment }),
                  interval == 1 || times[i+interval]-times[i-interval] <= 2*options.radius else { continue }
            var eligible = 0, anchors = [(Int,Int)](), candidates = [Track]()
            for y in stride(from:margin,to:h-margin,by:3*scale) { for x in stride(from:margin,to:w-margin,by:3*scale) {
                guard SurfaceTracking.cameraShapeCorrelation(images[i],images[i],x:x,y:y,referenceX:x,referenceY:y,half:half) != nil else { continue }
                eligible += 1
                guard let a = SurfaceTracking.cameraShapeCorrelation(images[i],images[i-interval],x:x,y:y,referenceX:x,referenceY:y,half:half), a > 0.95,
                      let c = SurfaceTracking.cameraShapeCorrelation(images[i],images[i+interval],x:x,y:y,referenceX:x,referenceY:y,half:half), c > 0.95 else { continue }
                anchors.append((x,y))
                candidates.append(.init(identity:[],identityHalf:half,observations:[i-interval,i,i+interval].map {
                    .init(frame:$0,x:x,y:y,level:0)
                }))
            } }
            guard anchors.count >= max(12,Int(ceil(Double(eligible)*0.6))),
                  anchors.map({ $0.0 }).max()!-anchors.map({ $0.0 }).min()! >= w/2,
                  anchors.map({ $0.1 }).max()!-anchors.map({ $0.1 }).min()! >= h/2 else { continue }
            tracksByInterval[interval,default:[]] += candidates
            stationaryFramesByInterval[interval,default:[]].insert(i)
        } }
        struct Row {
            let points: [Observation]; let automatic: Double; let delta: Double; let error: Double
            var footprints: PulseFootprints? = nil
            var validPixels: [Int]? = nil
            var weights: [Double]? = nil
        }
        var rows = [Int:[Row]]()
        var quietSourceRows = [Row]()
        let quietSourceGuards = ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_QUIET_SOURCE_GUARDS"] == "1" &&
            ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_JOINT_FIELD_FIT"] == "1"
        func gain(_ observation: Observation,_ maps: [SpatialField],globalOnly: Bool = false) -> Double {
            let i = observation.frame,image = images[i],map = maps[i].surface!
            let neutral = SurfaceLighting.Map(width:w,height:h,channelEV:neutralGains,guide:image.rgb,rowModel:false)
            var before = 0.0,after = 0.0
            for dy in -2...2 { for dx in -2...2 {
                let x = observation.x+dx,y = observation.y+dy,p = (y*w+x)*3
                let rgb = (0..<3).map { Double(image.rgb[p+$0]) }
                let out = SpatialRenderer.surfaceRGB(rgb,x:(Double(x)+0.5)/Double(w),y:(Double(y)+0.5)/Double(h),
                    map:globalOnly ? neutral : map,global:stops[i]+(globalOnly ? 0 : (maps[i].brightnessEV ?? 0)))
                for c in 0..<3 { let weight = [0.2126,0.7152,0.0722][c];before += weight*rgb[c];after += weight*out[c] }
            } }
            return log2(max(1e-9,after)/max(1e-9,before))
        }
        func curvature(_ points: [Observation],_ maps: [SpatialField],globalOnly: Bool = false) -> Double {
            let i = points[1].frame,alpha = (times[i]-times[points[0].frame])/(times[points[2].frame]-times[points[0].frame])
            return gain(points[1],maps,globalOnly:globalOnly)-(1-alpha)*gain(points[0],maps,globalOnly:globalOnly)-alpha*gain(points[2],maps,globalOnly:globalOnly)
        }
        func rowCurvature(_ row: Row,_ maps: [SpatialField],globalOnly: Bool = false) -> Double {
            guard let footprints = row.footprints,let validPixels = row.validPixels else { return curvature(row.points,maps,globalOnly:globalOnly) }
            let values = row.points.enumerated().map { j,observation -> Double in
                let i = observation.frame,image = images[i]
                let neutral = SurfaceLighting.Map(width:w,height:h,channelEV:neutralGains,guide:image.rgb,rowModel:false)
                return SpatialRenderer.sampledSurfaceGain(image:image,map:globalOnly ? neutral : maps[i].surface!,
                    global:stops[i]+(globalOnly ? 0 : (maps[i].brightnessEV ?? 0)),points:footprints[j],validPixels:validPixels,sampleWeights:row.weights) ?? .nan
            }
            let alpha = (times[row.points[1].frame]-times[row.points[0].frame])/(times[row.points[2].frame]-times[row.points[0].frame])
            return values[1]-(1-alpha)*values[0]-alpha*values[2]
        }
        func insertRow(_ points: [Observation],_ source: Double,_ error: Double,
                       footprints: PulseFootprints? = nil,validPixels: [Int]? = nil,weights: [Double]? = nil) {
            var row = Row(points:points,automatic:0,delta:0,error:error,footprints:footprints,validPixels:validPixels,weights:weights)
            let automatic = rowCurvature(row,fields)
            guard automatic.isFinite,let delta = CommonIlluminationComponent.pulseAdditionalCurvature(sourceExcursion:source,
                automaticGain:automatic,globalGain:options.spatialStrength < 1 ? rowCurvature(row,fields,globalOnly:true) : 0,
                strength:options.strength,spatial:options.spatialStrength) else { return }
            let requested: Double
            if significance {
                guard let significant = CommonIlluminationComponent.significantPulseDelta(delta,heldError:error,strength:options.strength,spatial:options.spatialStrength) else { return }
                requested = significant
            } else { requested = delta }
            row = Row(points:points,automatic:automatic,delta:requested,error:error,footprints:footprints,validPixels:validPixels,weights:weights)
            let key = points[1].y*w+points[1].x
            rows[key,default:[]].append(row)
        }
        for interval in intervals {
            let handler: TransportedPulseHandler? = denseMeasurements && interval > 1 ? { points,source,error,footprints,validPixels,weights in
                insertRow(points,source,error,footprints:footprints,validPixels:validPixels,weights:weights)
            } : nil
            let lowTextureHandler: TransportedPulseHandler? = denseMeasurements && ProcessInfo.processInfo.environment["FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_QUERIES"] == "1" ? { points,source,error,footprints,validPixels,weights in
                insertRow(points,source,error,footprints:footprints,validPixels:validPixels,weights:weights)
            } : nil
            let quietHandler: TransportedPulseHandler? = quietSourceGuards ? { points,_,error,footprints,validPixels,weights in
                quietSourceRows.append(.init(points:points,automatic:0,delta:0,error:error,footprints:footprints,validPixels:validPixels,weights:weights))
            } : nil
            pulseDiagnostics(samples:samples,images:images,tracks:tracksByInterval[interval] ?? [],cameraGuided:true,cameraHalf:half,
                frameInterval:interval,photometryImages:meterImages,stationaryCameraFrames:stationaryFramesByInterval[interval] ?? [],quietSourceProtected:quietHandler,lowTextureCertified:lowTextureHandler,
                transportedCertified:handler,certified:{ points,source,error in insertRow(points,source,error) })
        }
        let limit = 0.25*options.strength*options.spatialStrength
        let proposedPasses = maximumPasses ?? Int(ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_ITERATIONS"] ?? "1") ?? 1
        let passes = (1...3).contains(proposedPasses) ? proposedPasses : 1
        var current = fields
        let allRows = rows
        for phase in supplement ? [1,2] : [0] {
        let rows = allRows.mapValues { values in phase == 1 ? values.filter { $0.points[1].frame-$0.points[0].frame == 1 } : values }
        if phase == 2 {
            let eligible = rows.values.reduce(0) { total,values in
                let adjacent = Set(values.filter { $0.points[1].frame-$0.points[0].frame == 1 }.map { $0.points[1].frame })
                return total+values.filter { $0.points[1].frame-$0.points[0].frame > 1 && (jointIntervals || !adjacent.contains($0.points[1].frame)) }.count
            }
            if eligible < 12 {
                print("COMMON_LIGHT_PULSE_COMPOSITION_REJECTED", "sceneStart",samples[0].time,"phase",phase,"reason","insufficientRows","rows",eligible)
                continue
            }
        }
        var actualGains = rows.mapValues { values in values.map { rowCurvature($0,current) } }
        let phaseInitialGains = actualGains
        let quietSourceTargets = phase == 2 ? quietSourceRows.map { rowCurvature($0,current) } : []
        if phase == 2,quietSourceGuards { print("COMMON_LIGHT_QUIET_SOURCE_GUARDS","sceneStart",samples[0].time,"rows",quietSourceRows.count) }
        // Reuse frozen source evidence. Each pass measures the remaining actual
        // rendered gain error rather than applying the source pulse again.
        for pass in 0..<passes {
            var additions = [[(x:Int,y:Int,delta:Double)]](repeating:[],count:n)
            var additionFootprints = [PulseFootprints](repeating:[],count:n)
            var additionMasks = [[[Int]]](repeating:[],count:n)
            var additionWeights = [[[Double]]](repeating:[],count:n)
            func appendAddition(key: Int,frame: Int,delta: Double,observations: [Row]) {
                guard denseMeasurements,phase == 2 else { additions[frame].append((key%w,key/w,delta));return }
                var seen = Set<[UInt64]>()
                for row in observations { for (j,point) in row.points.enumerated() where point.frame == frame {
                    let footprint = row.footprints?[j] ?? (-2...2).flatMap { dy in (-2...2).map { dx in (x:Double(point.x+dx),y:Double(point.y+dy)) } }
                    let mask = row.validPixels ?? Array(footprint.indices)
                    let weights = row.weights ?? Array(repeating:1,count:footprint.count)
                    let signature = footprint.flatMap { [$0.x.bitPattern,$0.y.bitPattern] }+mask.map { UInt64($0) }+weights.map { $0.bitPattern }
                    guard seen.insert(signature).inserted else { continue }
                    additions[frame].append((key%w,key/w,delta));additionFootprints[frame].append(footprint);additionMasks[frame].append(mask);additionWeights[frame].append(weights)
                } }
            }
            var solvedKeys = 0,residualRejectedKeys = 0,limitRejectedKeys = 0
            for (key,observations) in rows {
                if multiscale && phase != 1 {
                    let adjacentFrames = Set(observations.filter { $0.points[1].frame-$0.points[0].frame == 1 }.map { $0.points[1].frame })
                    let widerFrames = Set(observations.filter { $0.points[1].frame-$0.points[0].frame > 1 }.map { $0.points[1].frame })
                    let variables = phase == 2 ? widerFrames.union(adjacentFrames) : nil
                    let constraints = observations.enumerated().compactMap { j,row -> PulseReconstruction.Constraint? in
                        let adjacent = row.points[1].frame-row.points[0].frame == 1
                        if phase == 2,!jointIntervals,!adjacent,adjacentFrames.contains(row.points[1].frame) { return nil }
                        return PulseReconstruction.Constraint(before:row.points[0].frame,middle:row.points[1].frame,after:row.points[2].frame,
                            excursion:row.automatic+row.delta-actualGains[key]![j],weight:1/max(0.001,row.error))
                    }
                    guard let solved = PulseReconstruction.solveCorrections(times:times,constraints:constraints,variableFrames:variables) else { continue }
                    let consistent = uncertaintyBounded
                        ? PulseReconstruction.residualsConsistent(solved.rowResiduals,errors:constraints.map { 1/$0.weight },scale:options.strength*options.spatialStrength)
                        : solved.maximumResidual < 0.01*options.strength
                    guard consistent else { residualRejectedKeys += 1;continue }
                    guard solved.signal.compactMap({ $0 }).allSatisfy({ abs($0) <= limit }) else { limitRejectedKeys += 1;continue }
                    solvedKeys += 1
                    for i in 0..<n { if let delta = solved.signal[i] { appendAddition(key:key,frame:i,delta:delta,observations:observations) } }
                    continue
                }
                var excursions = [Double?](repeating:nil,count:n),weights = [Double](repeating:0,count:n)
                for (j,row) in observations.enumerated() {
                    let i = row.points[1].frame
                    excursions[i] = pass == 0 ? row.delta : row.automatic+row.delta-actualGains[key]![j]
                    weights[i] = 1/max(0.001,row.error)
                }
                guard let solved = PulseReconstruction.solve(times:times,excursions:excursions,weights:weights,anchorEndpoints:anchorEndpoints),
                      solved.maximumResidual < 0.01*options.strength,
                      solved.signal.compactMap({ $0 }).allSatisfy({ abs($0) <= limit }) else { continue }
                for i in 0..<n { if let delta = solved.signal[i] { appendAddition(key:key,frame:i,delta:delta,observations:observations) } }
            }
            if phase == 2 {
                print("COMMON_LIGHT_PULSE_SUPPORT", "sceneStart",samples[0].time,"pass",pass+1,"keys",rows.count,
                      "solved",solvedKeys,"residualRejected",residualRejectedKeys,"limitRejected",limitRejectedKeys)
            }
            var candidate = current
            for i in 0..<n {
                guard additions[i].count >= 12 else { continue }
                let image = images[i],map = current[i].surface!
                if rendererFit,phase == 2 {
                    let original = fields[i].surface!.channelEV
                    let bounds: [(lower:Double,upper:Double)]? = boundedFit ? (0..<map.width*map.height).map { p in
                        let applied = (0..<3).map { Double(map.channelEV[p*3+$0])-Double(original[p*3+$0]) }
                        return (applied.map { -limit-$0 }.max()!,applied.map { limit-$0 }.min()!)
                    } : nil
                    guard let increments = SpatialRenderer.fitSurfaceIncrements(image:image,map:map,
                        global:stops[i]+(current[i].brightnessEV ?? 0),observations:additions[i],spatialRegularization:ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_SPATIAL_PRIOR"] == "1" ? 0.1 : 0,bounds:bounds,footprints:denseMeasurements ? additionFootprints[i] : nil,validPixels:denseMeasurements ? additionMasks[i] : nil,footprintWeights:denseMeasurements ? additionWeights[i] : nil) else { continue }
                    var gains = map.channelEV
                    for p in increments.indices { for c in 0..<3 { gains[p*3+c] += increments[p] } }
                    candidate[i].surface = .init(width:map.width,height:map.height,channelEV:gains,guide:map.guide,rowModel:map.rowModel)
                    continue
                }
                var sum = [Double](repeating:0,count:w*h),weight = sum
                let radius = 4*scale
                for point in additions[i] {
                    let center = (point.y*w+point.x)*3
                    for dy in -radius...radius { for dx in -radius...radius {
                        let x = point.x+dx,y = point.y+dy
                        guard (0..<w).contains(x),(0..<h).contains(y) else { continue }
                        let pixel = y*w+x
                        let distance = (0..<3).reduce(0.0) { $0+pow(log2(max(0.003,Double(image.rgb[pixel*3+$1]))/max(0.003,Double(image.rgb[center+$1]))),2) }
                        let k = (1-Double(abs(dx))/Double(radius+1))*(1-Double(abs(dy))/Double(radius+1))*exp(-distance/0.3)
                        sum[pixel] += k*point.delta;weight[pixel] += k
                    } }
                }
                var gains = map.channelEV
                // Preserve the baseline map and guidance. Sample only the new
                // neutral-EV residual onto its existing grid; no reference pixels
                // or detail images enter the native output renderer.
                for y in 0..<map.height { for x in 0..<map.width {
                    let basis = SpatialRenderer.surfaceBasis(x:(Double(x)+0.5)/Double(map.width),
                        y:(Double(y)+0.5)/Double(map.height),width:w,height:h)
                    let delta = basis.reduce(0.0) { $0+$1.1*sum[$1.0]/max(1,weight[$1.0]) }
                    let p = y*map.width+x
                    for c in 0..<3 { gains[p*3+c] += Float(delta) }
                } }
                candidate[i].surface = .init(width:map.width,height:map.height,channelEV:gains,guide:map.guide,rowModel:map.rowModel)
            }
            if phase == 2,denseMeasurements,boundedFit,jointIntervals,
               ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_TEMPORAL_FIT"] == "1" {
                // Block-coordinate fitting of actual temporal residuals. Only
                // source-certified variable frames can change; endpoint gains
                // enter each equation with their real presentation-time weights.
                var variables = [Int:Set<Int>]()
                for i in additions.indices { for point in additions[i] {
                    variables[point.y*w+point.x,default:[]].insert(i)
                } }
                for _ in 0..<4 {
                    if Task.isCancelled { return fields }
                    for i in candidate.indices {
                        var points = [(x:Int,y:Int,delta:Double)](),weights = [Double]()
                        var footprints = [[(x:Double,y:Double)]](),masks = [[Int]](),footprintWeights = [[Double]]()
                        for (key,observations) in rows where variables[key]?.contains(i) == true {
                            for row in observations {
                                guard let j = row.points.firstIndex(where:{ $0.frame == i }) else { continue }
                                let alpha = (times[row.points[1].frame]-times[row.points[0].frame])/(times[row.points[2].frame]-times[row.points[0].frame])
                                let coefficient = j == 1 ? 1 : j == 0 ? -(1-alpha) : -alpha
                                guard abs(coefficient) > 0.001 else { continue }
                                let remaining = row.automatic+row.delta-rowCurvature(row,candidate)
                                guard remaining.isFinite else { continue }
                                let point = row.points[j]
                                points.append((point.x,point.y,remaining/coefficient))
                                weights.append(coefficient*coefficient*0.0001/max(0.0001,row.error*row.error))
                                footprints.append(row.footprints?[j] ?? (-2...2).flatMap { dy in (-2...2).map { dx in (x:Double(point.x+dx),y:Double(point.y+dy)) } })
                                masks.append(row.validPixels ?? Array(footprints.last!.indices));footprintWeights.append(row.weights ?? Array(repeating:1,count:footprints.last!.count))
                            }
                        }
                        guard points.count >= 12 else { continue }
                        let map = candidate[i].surface!,original = fields[i].surface!.channelEV
                        let limits: [(lower:Double,upper:Double)] = (0..<map.width*map.height).map { p in
                            let applied = (0..<3).map { Double(map.channelEV[p*3+$0])-Double(original[p*3+$0]) }
                            return (applied.map { -limit-$0 }.max()!,applied.map { limit-$0 }.min()!)
                        }
                        guard let increment = SpatialRenderer.fitSurfaceIncrements(image:images[i],map:map,
                            global:stops[i]+(candidate[i].brightnessEV ?? 0),observations:points,
                            observationWeights:weights,bounds:limits,footprints:footprints,validPixels:masks,footprintWeights:footprintWeights) else { continue }
                        var gains = map.channelEV
                        for p in increment.indices { for c in 0..<3 { gains[p*3+c] += increment[p] } }
                        candidate[i].surface = .init(width:map.width,height:map.height,channelEV:gains,guide:map.guide,rowModel:map.rowModel)
                    }
                }
            }
            if phase == 2,denseMeasurements,boundedFit,jointIntervals,
               ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_PROJECTION"] == "1" {
                var variables = [Int:Set<Int>]()
                for i in additions.indices { for point in additions[i] { variables[point.y*w+point.x,default:[]].insert(i) } }
                for sweep in 0..<12 {
                    if Task.isCancelled { return fields }
                    var violations = 0,updates = 0
                    for key in rows.keys.sorted() {
                        for (index,row) in rows[key]!.enumerated() where row.points[1].frame-row.points[0].frame == 1 {
                            let target = row.automatic+row.delta
                            let error = rowCurvature(row,candidate)-target
                            let budget = min(abs(actualGains[key]![index]-target),abs(phaseInitialGains[key]![index]-target))+0.001*options.strength
                            guard error.isFinite,abs(error) > budget else { continue }
                            violations += 1
                            let alpha = (times[row.points[1].frame]-times[row.points[0].frame])/(times[row.points[2].frame]-times[row.points[0].frame])
                            var entries = [(frame:Int,node:Int)](),gradient = [Double](),values = [Double](),limits = [(lower:Double,upper:Double)]()
                            for (j,point) in row.points.enumerated() where variables[key]?.contains(point.frame) == true {
                                let i = point.frame,map = candidate[i].surface!,original = fields[i].surface!.channelEV
                                guard let terms = SpatialRenderer.surfaceGainJacobian(image:images[i],map:map,
                                    global:stops[i]+(candidate[i].brightnessEV ?? 0),point:(point.x,point.y),
                                    footprint:row.footprints?[j],validPixels:row.validPixels,sampleWeights:row.weights) else { continue }
                                let coefficient = j == 1 ? 1 : j == 0 ? -(1-alpha) : -alpha
                                for (node,response) in terms {
                                    entries.append((i,node));gradient.append(coefficient*response)
                                    let applied = (0..<3).map { Double(map.channelEV[node*3+$0])-Double(original[node*3+$0]) }
                                    values.append(applied[0]);limits.append((applied.map { -limit-$0+applied[0] }.max()!,applied.map { limit-$0+applied[0] }.min()!))
                                }
                            }
                            guard let projected = SpatialRenderer.boundedMeasurementProjection(values:values,gradient:gradient,bounds:limits,
                                measurement:error,allowed:(-budget*0.99)...(budget*0.99)) else { continue }
                            for i in Set(entries.map { $0.frame }).sorted() {
                                let map = candidate[i].surface!;var gains = map.channelEV
                                for k in entries.indices where entries[k].frame == i {
                                    let change = projected[k]-values[k]
                                    for c in 0..<3 { gains[entries[k].node*3+c] += Float(change) }
                                }
                                candidate[i].surface = .init(width:map.width,height:map.height,channelEV:gains,guide:map.guide,rowModel:map.rowModel)
                            }
                            updates += 1
                        }
                    }
                    print("COMMON_LIGHT_PULSE_PROJECTION","sceneStart",samples[0].time,"sweep",sweep+1,"violations",violations,"updates",updates)
                    if violations == 0 || updates == 0 { break }
                }
            }
            if phase == 2,boundedFit,ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_JOINT_FIELD_FIT"] == "1" {
                func jointProposal() -> [SpatialField]? {
                    struct LinearRow {
                        let terms: [(Int,Double)]
                        let error: Double
                        let budget: Double
                        let primary: Bool
                        let adjacent: Bool
                        var objectiveTolerance: Double = 0
                    }
                    let nodeCount = current[0].surface!.width*current[0].surface!.height
                    guard current.allSatisfy({ $0.surface!.width == current[0].surface!.width && $0.surface!.height == current[0].surface!.height }) else {
                        print("COMMON_LIGHT_JOINT_FIELD_FAILURE","sceneStart",samples[0].time,"pass",pass+1,"reason","mapTopology")
                        return nil
                    }
                    struct Differential {
                        let key: Int
                        let index: Int
                        let row: Row
                        let gradients: [[(Int,Double)]]
                    }
                    var differentials: [Differential] = [],authorized = Set<Int>()
                    for key in rows.keys.sorted() { for (index,row) in rows[key]!.enumerated() {
                        var gradients: [[(Int,Double)]] = []
                        for (j,point) in row.points.enumerated() {
                            let i = point.frame
                            guard let terms = SpatialRenderer.surfaceGainJacobian(image:images[i],map:current[i].surface!,
                                global:stops[i]+(current[i].brightnessEV ?? 0),point:(point.x,point.y),
                                footprint:row.footprints?[j],validPixels:row.validPixels,sampleWeights:row.weights) else { break }
                            gradients.append(terms.map { (i*nodeCount+$0.0,$0.1) })
                        }
                        guard gradients.count == 3 else { continue }
                        authorized.formUnion(gradients[1].map { $0.0 })
                        differentials.append(.init(key:key,index:index,row:row,gradients:gradients))
                    } }
                    let ids = authorized.sorted(),columns = Dictionary(uniqueKeysWithValues:ids.enumerated().map { ($0.element,$0.offset) })
                    guard !ids.isEmpty else {
                        print("COMMON_LIGHT_JOINT_FIELD_FAILURE","sceneStart",samples[0].time,"pass",pass+1,"reason","noAuthorizedNodes")
                        return nil
                    }
                    let trust = 0.03*options.strength*options.spatialStrength
                    var bounds: [(Double,Double)] = []
                    for id in ids {
                        let i = id/nodeCount,node = id%nodeCount
                        let original = fields[i].surface!.channelEV,map = current[i].surface!.channelEV
                        let applied = (0..<3).map { Double(map[node*3+$0])-Double(original[node*3+$0]) }
                        let low = max(-trust,applied.map { -limit-$0 }.max()!),high = min(trust,applied.map { limit-$0 }.min()!)
                        guard low <= 1e-7,high >= -1e-7 else {
                            print("COMMON_LIGHT_JOINT_FIELD_FAILURE","sceneStart",samples[0].time,"pass",pass+1,"reason","currentIncrementBudget")
                            return nil
                        }
                        bounds.append((min(low,0),max(high,0)))
                    }
                    var linear: [LinearRow] = []
                    for differential in differentials {
                        let row = differential.row,key = differential.key,index = differential.index
                        let i = row.points[1].frame
                        let alpha = (times[i]-times[row.points[0].frame])/(times[row.points[2].frame]-times[row.points[0].frame])
                        var gradient: [Int:Double] = [:]
                        for j in 0..<3 { for (id,value) in differential.gradients[j] {
                            if let column = columns[id] { gradient[column,default:0] += value*[-(1-alpha),1,-alpha][j] }
                        } }
                        let terms = gradient.keys.sorted().compactMap { column -> (Int,Double)? in
                            let value = gradient[column]!;return abs(value) > 1e-14 ? (column,value) : nil
                        }
                        guard !terms.isEmpty else { continue }
                        let target = row.automatic+row.delta,error = actualGains[key]![index]-target
                        let initial = phaseInitialGains[key]![index]-target,adjacent = row.points[1].frame-row.points[0].frame == 1
                        let allowance = (adjacent ? 0.001 : 0.02)*options.strength
                        let budget = max(abs(error),min(abs(error),abs(initial))+0.5*allowance)
                        let adjacentFrames = Set(rows[key]!.filter { $0.points[1].frame-$0.points[0].frame == 1 }.map { $0.points[1].frame })
                        let primary = !adjacent && (jointIntervals || !adjacentFrames.contains(i))
                        guard error.isFinite,budget.isFinite else { return nil }
                        let sourceTolerance = ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_JOINT_SOURCE_INTERVAL"] == "1"
                            ? row.error*options.strength*options.spatialStrength : 0
                        linear.append(.init(terms:terms,error:error,budget:budget,primary:primary,adjacent:adjacent,objectiveTolerance:sourceTolerance))
                    }
                    // These rows never authorize nodes or enter the source
                    // temporal reconstruction. They only constrain changes on
                    // nodes already authorized by independent event evidence.
                    for (index,row) in quietSourceRows.enumerated() where phase == 2 {
                        let middle = row.points[1].frame
                        let alpha = (times[middle]-times[row.points[0].frame])/(times[row.points[2].frame]-times[row.points[0].frame])
                        var gradient: [Int:Double] = [:],valid = true
                        for (j,point) in row.points.enumerated() {
                            let i = point.frame
                            guard let terms = SpatialRenderer.surfaceGainJacobian(image:images[i],map:current[i].surface!,global:stops[i]+(current[i].brightnessEV ?? 0),point:(point.x,point.y),footprint:row.footprints?[j],validPixels:row.validPixels,sampleWeights:row.weights) else { valid = false;break }
                            for (node,value) in terms {
                                if let column = columns[i*nodeCount+node] { gradient[column,default:0] += value*[-(1-alpha),1,-alpha][j] }
                            }
                        }
                        guard valid else { continue }
                        let terms = gradient.keys.sorted().compactMap { column -> (Int,Double)? in
                            let value = gradient[column]!;return abs(value) > 1e-14 ? (column,value) : nil
                        }
                        guard !terms.isEmpty else { continue }
                        let error = rowCurvature(row,current)-quietSourceTargets[index]
                        guard error.isFinite else { return nil }
                        linear.append(.init(terms:terms,error:error,budget:max(abs(error),0.0005*options.strength),primary:false,adjacent:false))
                    }
                    guard linear.filter({ $0.primary }).count >= 12 else {
                        print("COMMON_LIGHT_JOINT_FIELD_FAILURE","sceneStart",samples[0].time,"pass",pass+1,"reason","insufficientPrimaryRows","rows",linear.count)
                        return nil
                    }
                    let constraints = linear.map { PulseReconstruction.FieldRow(terms:$0.terms,error:$0.error,budget:$0.budget,weight:$0.primary ? 1 : 0,adjacent:$0.adjacent,objectiveTolerance:$0.objectiveTolerance) }
                    let tighterConvergence = ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_JOINT_CONVERGED_FIT"] == "1"
                    let iterationLimit = tighterConvergence ? 2000 : 400,convergenceTolerance = tighterConvergence ? 1e-10 : 1e-7
                    let boxPenalty = ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_JOINT_SCALED_PENALTY"] == "1" ? 0.01 : 1.0
                    guard let solved = PulseReconstruction.solveBoundedField(rows:constraints,bounds:bounds,maximumIterations:iterationLimit,
                        restoreFeasibility:ProcessInfo.processInfo.environment["FRANKLUMA_PULSE_JOINT_FEASIBLE_STEP"] == "1",convergenceTolerance:convergenceTolerance,boxPenalty:boxPenalty) else {
                        print("COMMON_LIGHT_JOINT_FIELD_FAILURE","sceneStart",samples[0].time,"pass",pass+1,"reason","solverFailure","variables",ids.count,"rows",linear.count)
                        return nil
                    }
                    guard solved.maximumViolation <= 1e-5 else {
                        print("COMMON_LIGHT_JOINT_FIELD_FAILURE","sceneStart",samples[0].time,"pass",pass+1,"reason","linearConstraintViolation","variables",ids.count,"rows",linear.count,"iterations",solved.iterations,"maximumLinearViolation",solved.maximumViolation)
                        return nil
                    }
                    var result = current
                    for i in result.indices {
                        let map = current[i].surface!;var gains = map.channelEV
                        for (column,id) in ids.enumerated() where id/nodeCount == i {
                            for c in 0..<3 { gains[(id%nodeCount)*3+c] += Float(solved.increments[column]) }
                        }
                        result[i].surface = .init(width:map.width,height:map.height,channelEV:gains,guide:map.guide,rowModel:map.rowModel)
                    }
                    print("COMMON_LIGHT_JOINT_FIELD","sceneStart",samples[0].time,"pass",pass+1,"variables",ids.count,
                          "rows",linear.count,"iterations",solved.iterations,"iterationLimit",iterationLimit,"convergenceTolerance",convergenceTolerance,"boxPenalty",boxPenalty,"primalResidual",solved.primalResidual,"dualResidual",solved.dualResidual,"iterateChange",solved.iterateChange,"maximumLinearViolation",solved.maximumViolation,"feasibilityScale",solved.feasibilityScale)
                    return result
                }
                if let joint = jointProposal() { candidate = joint }
                else { print("COMMON_LIGHT_JOINT_FIELD_UNAVAILABLE","sceneStart",samples[0].time,"pass",pass+1) }
            }
            // Bound the total increment relative to the original automatic map;
            // additional passes must not multiply the correction limit.
            var stepScale = 1.0
            for i in candidate.indices {
                let original = fields[i].surface!.channelEV
                let old = zip(current[i].surface!.channelEV,original).map { Double($0)-Double($1) }
                let proposed = zip(candidate[i].surface!.channelEV,original).map { Double($0)-Double($1) }
                guard let scale = CommonIlluminationComponent.boundedRefinementScale(current:old,proposed:proposed,limit:limit+(boundedFit && phase == 2 ? 1e-7 : 0)) else {
                    stepScale = 0
                    break
                }
                stepScale = min(stepScale,scale)
            }
            if stepScale > 0,stepScale < 1 {
                // Stay just inside the budget despite Float map rounding.
                stepScale *= 0.99
                for i in candidate.indices {
                    let map = candidate[i].surface!,old = current[i].surface!.channelEV
                    let gains = zip(old,map.channelEV).map { Float(Double($0)+stepScale*(Double($1)-Double($0))) }
                    candidate[i].surface = .init(width:map.width,height:map.height,channelEV:gains,guide:map.guide,rowModel:map.rowModel)
                }
            }
            let bounded = stepScale > 0 && candidate.indices.allSatisfy { i in
                zip(candidate[i].surface!.channelEV,fields[i].surface!.channelEV).allSatisfy {
                    abs(Double($0)-Double($1)) <= limit+1e-7
                }
            }
            guard bounded else {
                print("COMMON_LIGHT_PULSE_COMPOSITION_REJECTED", "pass",pass+1,"reason","totalIncrementLimit")
                break
            }
            let fullCandidate = candidate
            var acceptedTrial = false
            for fraction in backtrack && phase == 2 ? [1.0,0.5,0.25,0.125,0.0625] : [1.0] {
            if fraction < 1 {
                candidate = current
                for i in candidate.indices {
                    let map = fullCandidate[i].surface!,old = current[i].surface!.channelEV
                    let gains = zip(old,map.channelEV).map { Float(Double($0)+fraction*(Double($1)-Double($0))) }
                    candidate[i].surface = .init(width:map.width,height:map.height,channelEV:gains,guide:map.guide,rowModel:map.rowModel)
                }
            }
            var beforeEnergy = 0.0,afterEnergy = 0.0,checked = 0
            var regressedRows = 0, maximumErrorIncrease = 0.0
            var changedProtectedRows = 0
            var beforeAdjacentEnergy = 0.0,afterAdjacentEnergy = 0.0
            var proposalGains = [Int:[Double]]()
            for (key,observations) in rows {
            let adjacentFrames = Set(observations.filter { $0.points[1].frame-$0.points[0].frame == 1 }.map { $0.points[1].frame })
            for (j,row) in observations.enumerated() {
                let old = actualGains[key]![j]
                let new = rowCurvature(row,candidate),target = row.automatic+row.delta
                proposalGains[key,default:[]].append(new)
                let before = old-target,after = new-target
                let initial = phase == 2 ? phaseInitialGains[key]![j]-target : before
                if phase == 2,row.points[1].frame-row.points[0].frame == 1 {
                    beforeAdjacentEnergy += before*before;afterAdjacentEnergy += after*after
                    if !CommonIlluminationComponent.pulseErrorWithinBudget(proposed:after,current:before,initial:initial,allowance:0.001*options.strength) { changedProtectedRows += 1 }
                }
                let increase = abs(after)-abs(before)
                maximumErrorIncrease = max(maximumErrorIncrease,increase)
                if !CommonIlluminationComponent.pulseErrorWithinBudget(proposed:after,current:before,initial:initial,allowance:0.02*options.strength) { regressedRows += 1 }
                if phase != 2 || (row.points[1].frame-row.points[0].frame > 1 && (jointIntervals || !adjacentFrames.contains(row.points[1].frame))) {
                    beforeEnergy += before*before;afterEnergy += after*after;checked += 1
                }
            } }
            let adjacentPreserved = phase != 2 || afterAdjacentEnergy <= beforeAdjacentEnergy+1e-12
            let quietSourceRegressions = phase == 2 ? quietSourceRows.enumerated().filter { index,row in
                let difference = rowCurvature(row,candidate)-quietSourceTargets[index]
                return !difference.isFinite || abs(difference) > 0.001*options.strength+1e-9
            }.count : 0
            guard adjacentPreserved,changedProtectedRows == 0,quietSourceRegressions == 0,regressedRows == 0,checked >= 12,afterEnergy < beforeEnergy*0.9 else {
                let reason = quietSourceRegressions > 0 ? "quietSourceProtection" : !adjacentPreserved || changedProtectedRows > 0 ? "adjacentProtection" : regressedRows > 0 ? "patchRegression" : checked < 12 ? "insufficientRows" : "insufficientImprovement"
                print("COMMON_LIGHT_PULSE_COMPOSITION_REJECTED", "sceneStart",samples[0].time,"phase",phase,"pass",pass+1,"reason",reason,
                      "rows",checked,"regressedRows",regressedRows,"changedProtectedRows",changedProtectedRows,"quietSourceRegressions",quietSourceRegressions,"maximumErrorIncrease",maximumErrorIncrease,
                      "stepScale",stepScale*fraction,"beforeEnergy",beforeEnergy,"afterEnergy",afterEnergy,
                      "beforeAdjacentEnergy",beforeAdjacentEnergy,"afterAdjacentEnergy",afterAdjacentEnergy)
                continue
            }
            print("COMMON_LIGHT_PULSE_COMPOSITION", "sceneStart",samples[0].time,"phase",phase,"pass",pass+1,"stepScale",stepScale*fraction,"rows",checked,"beforeRMS",sqrt(beforeEnergy/Double(checked)),"afterRMS",sqrt(afterEnergy/Double(checked)))
            current = candidate
            actualGains = proposalGains
            acceptedTrial = true
            break
            }
            if !acceptedTrial { break }
        }
        }
        return current
    }
    static func apply(samples: [ExposureSample], stops: [Double], fields: [SpatialField], options: SceneSettings,
                      sourceComponent: Bool = false) -> [SpatialField] {
        guard samples.count >= 5, stops.count == samples.count, fields.count == samples.count,
              options.strength > 0, options.spatialStrength > 0,
              samples.allSatisfy({ $0.thumbnail != nil }) else { return fields }
        let images = samples.map { $0.thumbnail! }, w = images[0].width, h = images[0].height
        guard images.allSatisfy({ $0.width == w && $0.height == h }),
              fields.allSatisfy({ $0.surface?.width == w && $0.surface?.height == h && $0.surface?.rowModel != true }) else { return fields }
        func light(_ image: SpatialThumbnail,_ p: Int) -> Double {
            0.2126*Double(image.rgb[p*3])+0.7152*Double(image.rgb[p*3+1])+0.0722*Double(image.rgb[p*3+2])
        }
        func level(_ image: SpatialThumbnail,_ x: Int,_ y: Int) -> Double {
            var sum = 0.0
            for dy in -2...2 { for dx in -2...2 { sum += light(image,(y+dy)*w+x+dx) } }
            return log2(max(1e-9,sum/25))
        }
        var active = [Track](), completed = [Track](), shortDonors = [Track]()
        let traceComponent = sourceComponent && ProcessInfo.processInfo.environment["FRANKLUMA_COMMON_TRACE"] == "1"
        let pulseTrace = sourceComponent && ProcessInfo.processInfo.environment["FRANKLUMA_COMMON_PULSE_DIAGNOSTICS"] == "1"
        let wideIdentity = sourceComponent && ProcessInfo.processInfo.environment["FRANKLUMA_COMMON_WIDE_IDENTITY"] == "1"
        var previous: SurfaceTracking.Prepared?
        for i in images.indices {
            if Task.isCancelled { return fields }
            let current = SurfaceTracking.Prepared(images[i])
            var continued = [Track]()
            for var track in active {
                let last = track.observations.last!
                guard samples[i].segment == samples[i-1].segment,
                      let match = SurfaceTracking.match(previous!,current,x: last.x,y: last.y,subpixel: false),
                      match.confidence*match.photometricConfidence > 0.6,
                      let identity = PersistentSurfaceIdentity.descriptor(images[i],x: Double(match.x),y: Double(match.y),half: track.identityHalf),
                      PersistentSurfaceIdentity.agrees(track.identity,identity) else {
                    if track.observations.count >= 5 { completed.append(track) }
                    else if (traceComponent || pulseTrace) && track.observations.count >= 2 { shortDonors.append(track) }
                    continue
                }
                track.observations.append(.init(frame: i,x: match.x,y: match.y,level: level(images[i],match.x,match.y)))
                continued.append(track)
            }
            active = continued
            // Replace ended trajectories from source evidence. Existing tracks
            // keep their identity and membership across the lighting episode.
            for y in stride(from: 7,to: h-7,by: 6) { for x in stride(from: 7,to: w-7,by: 6) {
                let localIdentity = PersistentSurfaceIdentity.descriptor(images[i],x: Double(x),y: Double(y),half: 2)
                // A secondary wide track must not suppress a primary seed.
                // Fallback candidates still avoid either bank's occupied centre.
                if active.contains(where: {
                    (!wideIdentity || localIdentity == nil || $0.identityHalf == 2)
                        && abs($0.observations.last!.x-x) <= 2 && abs($0.observations.last!.y-y) <= 2
                }) { continue }
                let identityHalf = localIdentity == nil && wideIdentity ? 6 : 2
                guard let identity = localIdentity ?? (wideIdentity
                    ? PersistentSurfaceIdentity.descriptor(images[i],x: Double(x),y: Double(y),half: 6) : nil) else { continue }
                active.append(.init(identity: identity,identityHalf: identityHalf,
                    observations: [.init(frame: i,x: x,y: y,level: level(images[i],x,y))]))
            } }
            previous = current
        }
        completed += active.filter { $0.observations.count >= 5 }
        if traceComponent || pulseTrace { shortDonors += active.filter { (2..<5).contains($0.observations.count) } }
        if pulseTrace { pulseDiagnostics(samples: samples,images: images,tracks: completed+shortDonors) }
        let componentConfiguration = CommonIlluminationComponent.Configuration(radius: options.radius,mode: options.mode,
            requireIndependentEvents: ProcessInfo.processInfo.environment["FRANKLUMA_COMMON_LIGHT_SAME_EVENT"] != "1",
            allowSupportedRuns: ProcessInfo.processInfo.environment["FRANKLUMA_COMMON_SUPPORTED_RUNS"] == "1")
        let sourceTracks: [CommonIlluminationComponent.Track] = sourceComponent ? completed.map { track in
            .init(observations: track.observations.map {
                .init(frame: $0.frame,x: $0.x,y: $0.y,level: $0.level)
            }) } : []
        let componentEstimates = sourceComponent ? CommonIlluminationComponent.estimate(times: samples.map(\.time),
            tracks: sourceTracks,configuration: componentConfiguration) : []
        if traceComponent {
            let hypotheticalPairs: [CommonIlluminationComponent.Track] = shortDonors.map { track in
                .init(observations: track.observations.map { .init(frame: $0.frame,x: $0.x,y: $0.y,level: $0.level) })
            }
            for (kind,additional) in [("actual",[CommonIlluminationComponent.Track]()),("hypotheticalShortPairs",hypotheticalPairs)] {
                let edges = CommonIlluminationComponent.edgeDiagnostics(frameCount: samples.count,tracks: sourceTracks,
                    additionalDonors: additional,configuration: componentConfiguration)
                var longest = 0, run = 0
                for edge in edges {
                    run = edge.rejection == nil ? run+1 : 0
                    longest = max(longest,run)
                }
                let first = edges.first { $0.rejection != nil }
                let summary: [String: Any] = ["kind": kind,"sceneStart": samples[0].time,"frames": samples.count,
                    "shortDonors": additional.count,"supportedEdges": edges.filter { $0.rejection == nil }.count,
                    "longestSupportedRunEdges": longest,
                    "quorumFailures": edges.filter { $0.rejection == .insufficientQuorum }.count,
                    "opposingSignFailures": edges.filter { $0.rejection == .opposingSigns }.count,
                    "weakHalfFailures": edges.filter { $0.rejection == .weakSpatialHalf }.count,
                    "firstFailureFrame": first?.frame ?? -1,"firstFailureCandidates": first?.candidateCount ?? 0,
                    "firstFailureIndependent": first?.independentCount ?? 0,
                    "firstFailureReason": first?.rejection?.rawValue ?? "none"]
                if let data = try? JSONSerialization.data(withJSONObject: summary,options: [.sortedKeys]),
                   let json = String(data: data,encoding: .utf8) { print("COMMON_LIGHT_SOURCE_EDGES",json) }
            }
        }
        var calibratedPrimary = 0, calibratedWide = 0
        let gainAbsence = sourceComponent && ProcessInfo.processInfo.environment["FRANKLUMA_COMMON_GAIN_ABSENCE"] == "1"
        let automaticGlobal = sourceComponent ? zip(stops,fields).map { $0+($1.brightnessEV ?? 0) } : []
        var absenceCalibrated = 0
        // Spatial's global remainder must follow the renderer's highlight
        // protection, rather than assuming a nominal EV is the actual gain.
        let neutralMap: SurfaceLighting.Map? = sourceComponent && options.spatialStrength < 1
            ? .init(width: w,height: h,channelEV: Array(repeating: 0,count: w*h*3),guide: images[0].rgb,rowModel: false) : nil
        var measurements = Array(repeating: [Measurement](),count: samples.count)
        for (trackIndex,track) in completed.enumerated() {
            let levels = track.observations.map(\.level)
            var globalGain = Array(repeating: 0.0,count: track.observations.count)
            let outputLevels = track.observations.enumerated().map { j,observation -> Double in
                let i = observation.frame, image = images[i], map = fields[i].surface!
                var sum = 0.0, globalSum = 0.0
                for dy in -2...2 { for dx in -2...2 {
                    let x = observation.x+dx,y = observation.y+dy,p = (y*w+x)*3
                    let sourceRGB = (0..<3).map { Double(image.rgb[p+$0]) }
                    let rgb = SpatialRenderer.surfaceRGB(sourceRGB,
                        x: (Double(x)+0.5)/Double(w),y: (Double(y)+0.5)/Double(h),map: map,
                        global: stops[i]+(fields[i].brightnessEV ?? 0))
                    sum += 0.2126*rgb[0]+0.7152*rgb[1]+0.0722*rgb[2]
                    if let neutralMap {
                        let globalRGB = SpatialRenderer.surfaceRGB(sourceRGB,x: (Double(x)+0.5)/Double(w),
                            y: (Double(y)+0.5)/Double(h),map: neutralMap,global: stops[i])
                        globalSum += 0.2126*globalRGB[0]+0.7152*globalRGB[1]+0.0722*globalRGB[2]
                    }
                } }
                if neutralMap != nil { globalGain[j] = log2(max(1e-9,globalSum/25))-observation.level }
                return log2(max(1e-9,sum/25))
            }
            if sourceComponent {
                // All fields here are automatic. AppModel adds the user's
                // manual frame adjustments after scene calculation finishes.
                let gain = zip(outputLevels,levels).map(-)
                let primaryCalibration = CommonIlluminationComponent.calibrate(estimate: componentEstimates[trackIndex],
                    renderedGain: gain,globalGain: globalGain,strength: options.strength,spatial: options.spatialStrength,
                    configuration: componentConfiguration)
                guard let calibration = primaryCalibration ?? (gainAbsence
                    ? CommonIlluminationComponent.calibrateAbsence(times: samples.map(\.time),
                        frames: track.observations.map(\.frame),sourceLevels: levels,renderedGain: gain,globalGain: globalGain,
                        automaticGlobal: automaticGlobal,strength: options.strength,spatial: options.spatialStrength,
                        configuration: componentConfiguration) : nil) else { continue }
                if primaryCalibration == nil { absenceCalibrated += 1 }
                if track.identityHalf == 2 { calibratedPrimary += 1 } else { calibratedWide += 1 }
                for (j,observation) in track.observations.enumerated() {
                    measurements[observation.frame].append(.init(x: observation.x,y: observation.y,
                        target: outputLevels[j]+calibration.delta[j]))
                }
                continue
            }
            let trends = options.mode == .steady
                ? Array(repeating: ExposureMath.median(levels),count: levels.count)
                : ExposureMath.smoothTargets(times: track.observations.map { samples[$0.frame].time },levels: levels,radius: options.radius,preserveShortRamps: true)
            let required = track.observations.enumerated().map { j,observation -> Double in
                let globalTarget = observation.level+stops[observation.frame]
                let localTarget = observation.level+options.strength*(trends[j]-observation.level)
                return globalTarget+options.spatialStrength*(localTarget-globalTarget)-outputLevels[j]
            }
            // The shot/global stage owns brightness calibration. Residual
            // refinement removes rapid errors, without re-anchoring each
            // fragmented surface to a new constant or gradual brightness.
            let rapid = rapidResidual(times: track.observations.map { samples[$0.frame].time },
                required: required,radius: options.radius,mode: options.mode)
            for (j,observation) in track.observations.enumerated() {
                measurements[observation.frame].append(.init(x: observation.x,y: observation.y,target: outputLevels[j]+rapid[j]))
            }
        }
        if sourceComponent && ProcessInfo.processInfo.environment["FRANKLUMA_COMMON_TRACE"] == "1" {
            let primary = completed.indices.filter { completed[$0].identityHalf == 2 }
            let wide = completed.indices.filter { completed[$0].identityHalf == 6 }
            func accepted(_ indices: [Int]) -> Int {
                indices.filter { componentEstimates[$0].state == .supported || componentEstimates[$0].state == .absent }.count
            }
            print("COMMON_LIGHT_COVERAGE", "frames",samples.count,"primaryTracks",primary.count,"wideTracks",wide.count,
                  "sourcePrimary",accepted(primary),"sourceWide",accepted(wide),
                  "independentSourcePrimary",primary.filter { componentEstimates[$0].independentlyValidated }.count,
                  "independentSourceWide",wide.filter { componentEstimates[$0].independentlyValidated }.count,
                  "calibratedPrimary",calibratedPrimary,"calibratedWide",calibratedWide,
                  "absenceCalibrated",absenceCalibrated,
                  "framesWithFitQuorum",measurements.filter { $0.count >= 12 }.count)
        }
        var result = fields
        var fittedFrames = 0
        for i in images.indices {
            if Task.isCancelled { return fields }
            let points = measurements[i]
            guard points.count >= 12 else { continue }
            let image = images[i], map = fields[i].surface!
            var rendered = [Float](); rendered.reserveCapacity(image.rgb.count)
            for y in 0..<h { for x in 0..<w {
                let p = (y*w+x)*3
                rendered += SpatialRenderer.surfaceRGB((0..<3).map { Double(image.rgb[p+$0]) },
                    x: (Double(x)+0.5)/Double(w),y: (Double(y)+0.5)/Double(h),map: map,
                    global: stops[i]+(fields[i].brightnessEV ?? 0)).map(Float.init)
            } }
            let output = SpatialThumbnail(width: w,height: h,rgb: rendered)
            func chroma(_ p: Int) -> (Double,Double) {
                let r = max(0.003,Double(image.rgb[p*3])),g = max(0.003,Double(image.rgb[p*3+1])),b = max(0.003,Double(image.rgb[p*3+2]))
                return (log2(r/g),log2(b/g))
            }
            var raw = Array(repeating: [PersistentLightingSolver.Weight](),count: w*h)
            var compatibility = Array(repeating: 0.0,count: w*h)
            for (j,point) in points.enumerated() {
                let colour = chroma(point.y*w+point.x)
                for dy in -4...4 { for dx in -4...4 {
                    guard (0..<w).contains(point.x+dx), (0..<h).contains(point.y+dy) else { continue }
                    let p = (point.y+dy)*w+point.x+dx,c = chroma(p)
                    let appearance = exp(-(pow(c.0-colour.0,2)+pow(c.1-colour.1,2))/0.09)
                    compatibility[p] = max(compatibility[p],appearance)
                    let weight = (1-Double(abs(dx))/5)*(1-Double(abs(dy))/5)*appearance
                    if weight > 1e-12 { raw[p].append(.init(index: j,value: weight)) }
                } }
            }
            let basis = PersistentLightingBasis.normalize(raw,width: w,height: h,compatibility: compatibility)
            var rows = [PersistentLightingSolver.Sample]()
            for point in points {
                var pixels = [PersistentLightingSolver.Pixel]()
                for dy in -2...2 { for dx in -2...2 {
                    let p = (point.y+dy)*w+point.x+dx
                    pixels.append(.init(light: light(output,p)/25,weights: basis[p]))
                } }
                rows.append(.init(before: [.init(light: exp2(point.target),weights: [])],after: pixels,target: 0))
            }
            let problem = PersistentLightingSolver.Problem(samples: rows,count: points.count,ridge: 0.05,
                limit: 0.25*options.strength*options.spatialStrength)
            guard let coefficients = PersistentLightingSolver.fit(problem) else { continue }
            let zero = Array(repeating: 0.0,count: points.count)
            let before = rows.compactMap { PersistentLightingSolver.response($0,coefficients: zero)?.error }
            let after = rows.compactMap { PersistentLightingSolver.response($0,coefficients: coefficients)?.error }
            guard before.count == rows.count, after.count == rows.count,
                  after.reduce(0,{ $0+$1*$1 }) < before.reduce(0,{ $0+$1*$1 })*0.95,
                  zip(before,after).allSatisfy({ abs($1) <= abs($0)+0.02*options.strength }) else { continue }
            var gains = map.channelEV
            for p in basis.indices {
                let delta = basis[p].reduce(0) { $0+coefficients[$1.index]*$1.value }
                for c in 0..<3 { gains[p*3+c] += Float(delta) }
            }
            result[i].surface = .init(width: w,height: h,channelEV: gains,guide: map.guide,rowModel: map.rowModel)
            fittedFrames += 1
        }
        if sourceComponent && ProcessInfo.processInfo.environment["FRANKLUMA_COMMON_TRACE"] == "1" {
            print("COMMON_LIGHT_FITTED_FRAMES",fittedFrames,"of",samples.count)
        }
        return result
    }
}
