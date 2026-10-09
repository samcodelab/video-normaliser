import XCTest
import CoreImage
@testable import FrankLuma

final class SpatialRendererTests: XCTestCase {
    func testWeightedTransportedGainMatchesRenderedRadianceAndJacobian() throws {
        let w = 16,h = 16
        let image = SpatialThumbnail(width:w,height:h,rgb:(0..<w*h).flatMap { p -> [Float] in
            let value = Float(0.15+Double(p%7)*0.08)
            return [value,value*0.7,value*0.4]
        })
        let map = SurfaceLighting.Map(width:2,height:2,channelEV:[0,0,0,0.8,0.8,0.8,-0.3,-0.3,-0.3,0.5,0.5,0.5],guide:Array(repeating:[Float(0.3),0.21,0.12],count:4).flatMap { $0 },rowModel:false)
        let points = [(x:6.25,y:6.5),(x:7.25,y:6.5),(x:8.25,y:6.5)]
        let weights = [0.25,0.5,0.25],valid = [0,1,2]
        func independent(_ field: SurfaceLighting.Map) -> Double {
            var before = 0.0,after = 0.0
            for i in points.indices {
                let p = points[i],x = Int(p.x),y = Int(p.y),fx = p.x-Double(x),fy = p.y-Double(y)
                for (dx,dy,a) in [(0,0,(1-fx)*(1-fy)),(1,0,fx*(1-fy)),(0,1,(1-fx)*fy),(1,1,fx*fy)] {
                    let pixel = ((y+dy)*w+x+dx)*3
                    let rgb = (0..<3).map { Double(image.rgb[pixel+$0]) }
                    let out = SpatialRenderer.surfaceRGB(rgb,x:(Double(x+dx)+0.5)/Double(w),y:(Double(y+dy)+0.5)/Double(h),map:field,global:0.6)
                    for c in 0..<3 { let luma = [0.2126,0.7152,0.0722][c];before += weights[i]*a*luma*rgb[c];after += weights[i]*a*luma*out[c] }
                }
            }
            return log2(after/before)
        }
        let gain = try XCTUnwrap(SpatialRenderer.sampledSurfaceGain(image:image,map:map,global:0.6,points:points,validPixels:valid,sampleWeights:weights))
        XCTAssertEqual(gain,independent(map),accuracy:1e-12)
        let jac = try XCTUnwrap(SpatialRenderer.surfaceGainJacobian(image:image,map:map,global:0.6,point:(7,7),footprint:points,validPixels:valid,sampleWeights:weights))
        for (node,derivative) in jac {
            var plusEV = map.channelEV,minusEV = map.channelEV
            for c in 0..<3 { plusEV[node*3+c] += 0.001;minusEV[node*3+c] -= 0.001 }
            let plus = SurfaceLighting.Map(width:map.width,height:map.height,channelEV:plusEV,guide:map.guide,rowModel:false)
            let minus = SurfaceLighting.Map(width:map.width,height:map.height,channelEV:minusEV,guide:map.guide,rowModel:false)
            XCTAssertEqual(derivative,(independent(plus)-independent(minus))/0.002,accuracy:0.0001)
        }
        let observations = Array(repeating:(x:7,y:7,delta:0.01),count:12)
        let footprints = Array(repeating:points,count:12),masks = Array(repeating:valid,count:12)
        let increments = try XCTUnwrap(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0.6,
            observations:observations,footprints:footprints,validPixels:masks,footprintWeights:Array(repeating:weights,count:12)))
        var fittedEV = map.channelEV
        for node in increments.indices { for c in 0..<3 { fittedEV[node*3+c] += increments[node] } }
        let fitted = SurfaceLighting.Map(width:map.width,height:map.height,channelEV:fittedEV,guide:map.guide,rowModel:false)
        XCTAssertEqual(independent(fitted)-independent(map),0.01,accuracy:0.001)
        XCTAssertNil(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0.6,
            observations:observations,footprints:footprints,validPixels:masks,footprintWeights:[[1]]))
        XCTAssertNil(SpatialRenderer.sampledSurfaceGain(image:image,map:map,global:0,points:points,validPixels:valid,sampleWeights:[1]))
        XCTAssertNil(SpatialRenderer.surfaceGainJacobian(image:image,map:map,global:0,point:(7,7),footprint:points,sampleWeights:[1,0,1]))
    }

    func testTransportedGainSamplesRenderedRadianceAfterHighlightResponse() throws {
        let w = 4,h = 4
        let rgb = (0..<w*h).flatMap { p -> [Float] in p%w <= 1 ? [0.7,0.02,0.01] : [0.05,0.1,0.5] }
        let image = SpatialThumbnail(width:w,height:h,rgb:rgb)
        let map = SurfaceLighting.Map(width:2,height:2,channelEV:Array(repeating:1,count:12),guide:Array(repeating:0.1,count:12),rowModel:false)
        let result = try XCTUnwrap(SpatialRenderer.sampledSurfaceGain(image:image,map:map,global:0,points:[(1.5,1)],validPixels:[0]))
        let luma = [0.2126,0.7152,0.0722]
        func light(_ v: [Double]) -> Double { zip(v,luma).reduce(0) { $0+$1.0*$1.1 } }
        let left = (0..<3).map { Double(rgb[(1*w+1)*3+$0]) },right = (0..<3).map { Double(rgb[(1*w+2)*3+$0]) }
        let renderedLeft = SpatialRenderer.surfaceRGB(left,x:1.5/4,y:1.5/4,map:map,global:0)
        let renderedRight = SpatialRenderer.surfaceRGB(right,x:2.5/4,y:1.5/4,map:map,global:0)
        XCTAssertEqual(result,log2((light(renderedLeft)+light(renderedRight))/(light(left)+light(right))),accuracy:1e-12)
        let blend = zip(left,right).map { ($0+$1)/2 }
        let incorrect = log2(light(SpatialRenderer.surfaceRGB(blend,x:2.0/4,y:1.5/4,map:map,global:0))/light(blend))
        XCTAssertGreaterThan(abs(result-incorrect),0.05)
        XCTAssertNil(SpatialRenderer.sampledSurfaceGain(image:image,map:map,global:0,points:[(1.5,1)],validPixels:[1]))
        XCTAssertNil(SpatialRenderer.sampledSurfaceGain(image:image,map:map,global:0,points:[(1.5,1)],validPixels:[0,0]))
        XCTAssertNil(SpatialRenderer.sampledSurfaceGain(image:image,map:map,global:0,points:[(.nan,1)],validPixels:[0]))
    }

    func testRendererFitUsesFractionalObservedFootprintsAndMasks() throws {
        let w = 96,h = 56,mw = 24,mh = 14
        let rgb = (0..<w*h*3).map { Float(0.07+Double(($0*173+31)%997)/997*0.13) }
        let image = SpatialThumbnail(width:w,height:h,rgb:rgb)
        var guide = [Float]()
        for y in 0..<mh { for x in 0..<mw {
            let p = ((y*4+2)*w+x*4+2)*3
            guide += Array(rgb[p..<p+3])
        } }
        let map = SurfaceLighting.Map(width:mw,height:mh,channelEV:Array(repeating:0,count:mw*mh*3),guide:guide,rowModel:false)
        var observations = [(x:Int,y:Int,delta:Double)](),footprints = [[(x:Double,y:Double)]]()
        for y in stride(from:12,through:44,by:8) { for x in stride(from:12,through:84,by:8) {
            observations.append((x,y,x < 48 ? 0.08 : -0.08))
            footprints.append((-2...2).flatMap { dy in (-2...2).map { dx in (Double(x+dx)+0.25,Double(y+dy)-0.25) } })
        } }
        let masks = observations.map { _ in Array(1..<25) }
        let bounds = Array(repeating:(lower:-0.1,upper:0.1),count:mw*mh)
        let increments = try XCTUnwrap(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0,
            observations:observations,bounds:bounds,footprints:footprints,validPixels:masks))
        var gains = map.channelEV
        for p in increments.indices { for c in 0..<3 { gains[p*3+c] += increments[p] } }
        let fitted = SurfaceLighting.Map(width:mw,height:mh,channelEV:gains,guide:guide,rowModel:false)
        var energy = 0.0
        for i in observations.indices {
            let original = try XCTUnwrap(SpatialRenderer.sampledSurfaceGain(image:image,map:map,global:0,points:footprints[i],validPixels:masks[i]))
            let output = try XCTUnwrap(SpatialRenderer.sampledSurfaceGain(image:image,map:fitted,global:0,points:footprints[i],validPixels:masks[i]))
            energy += pow(output-original-observations[i].delta,2)
        }
        XCTAssertLessThan(sqrt(energy/Double(observations.count)),0.015)
        for value in increments { XCTAssertLessThanOrEqual(abs(Double(value)),0.1000001) }
        XCTAssertEqual(fitted.guide,map.guide)
        XCTAssertNil(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0,observations:observations,footprints:[],validPixels:masks))
    }

    func testRendererGuidedFitReproducesOpposingPatchGains() throws {
        let w = 96,h = 56,mw = 24,mh = 14
        let rgb = (0..<w*h*3).map { Float(0.07+Double(($0*173+31)%997)/997*0.13) }
        let image = SpatialThumbnail(width:w,height:h,rgb:rgb)
        var guide = [Float]()
        for y in 0..<mh { for x in 0..<mw {
            let p = ((y*4+2)*w+x*4+2)*3
            guide += Array(rgb[p..<p+3])
        } }
        let map = SurfaceLighting.Map(width:mw,height:mh,channelEV:Array(repeating:0,count:mw*mh*3),guide:guide,rowModel:false)
        var points = [(x:Int,y:Int,delta:Double)]()
        for y in stride(from:12,through:44,by:8) { for x in stride(from:12,through:84,by:8) {
            points.append((x,y,x < 48 ? 0.08 : -0.08))
        } }
        let increments = try XCTUnwrap(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0,observations:points))
        var gains = map.channelEV
        for p in increments.indices { for c in 0..<3 { gains[p*3+c] += increments[p] } }
        let fitted = SurfaceLighting.Map(width:mw,height:mh,channelEV:gains,guide:guide,rowModel:false)
        var energy = 0.0
        for point in points {
            var original = 0.0,output = 0.0
            for dy in -2...2 { for dx in -2...2 {
                let x = point.x+dx,y = point.y+dy,p = (y*w+x)*3
                let input = (0..<3).map { Double(rgb[p+$0]) }
                let result = SpatialRenderer.surfaceRGB(input,x:(Double(x)+0.5)/Double(w),y:(Double(y)+0.5)/Double(h),map:fitted,global:0)
                for (c,weight) in [0.2126,0.7152,0.0722].enumerated() { original += input[c]*weight;output += result[c]*weight }
            } }
            let error = log2(output/original)-point.delta
            energy += error*error
        }
        XCTAssertLessThan(sqrt(energy/Double(points.count)),0.015)
        XCTAssertEqual(increments.first,0)
        XCTAssertEqual(increments.last,0)
        XCTAssertEqual(fitted.guide,map.guide)
        // The left region has no remaining positive budget. It must not
        // prevent the independent right region from receiving its correction.
        let limits: [(lower:Double,upper:Double)] = (0..<mw*mh).map { (-0.25,$0%mw < mw/2 ? 0 : 0.25) }
        let bounded = try XCTUnwrap(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0,observations:points,bounds:limits))
        for p in bounded.indices {
            XCTAssertGreaterThanOrEqual(Double(bounded[p]),limits[p].lower-1e-7)
            XCTAssertLessThanOrEqual(Double(bounded[p]),limits[p].upper+1e-7)
        }
        var boundedGains = map.channelEV
        for p in bounded.indices { for c in 0..<3 { boundedGains[p*3+c] += bounded[p] } }
        let boundedMap = SurfaceLighting.Map(width:mw,height:mh,channelEV:boundedGains,guide:guide,rowModel:false)
        var sourceLight = 0.0,outputLight = 0.0
        for y in 26...30 { for x in 74...78 {
            let p = (y*w+x)*3,input = (0..<3).map { Double(rgb[p+$0]) }
            let output = SpatialRenderer.surfaceRGB(input,x:(Double(x)+0.5)/Double(w),y:(Double(y)+0.5)/Double(h),map:boundedMap,global:0)
            for (c,weight) in [0.2126,0.7152,0.0722].enumerated() { sourceLight += input[c]*weight;outputLight += output[c]*weight }
        } }
        XCTAssertLessThan(log2(outputLight/sourceLight),-0.06)
    }

    func testBoundedProjectionProtectsMeasurementAndPreservesBudgets() throws {
        let result = try XCTUnwrap(SpatialRenderer.boundedMeasurementProjection(values:[0.1,-0.1],gradient:[1,-1],bounds:[(-0.25,0.25),(-0.25,0.25)],measurement:0.2,allowed:(-0.001)...0.001))
        XCTAssertEqual(result[0]-result[1],0.001,accuracy:1e-12)
        let saturated = try XCTUnwrap(SpatialRenderer.boundedMeasurementProjection(values:[0],gradient:[1],bounds:[(-0.01,0.01)],measurement:0.2,allowed:(-0.001)...0.001))
        XCTAssertEqual(saturated[0],-0.01)
        XCTAssertGreaterThan(0.2+saturated[0],0.001) // Caller must recheck infeasible constraints.
        XCTAssertNil(SpatialRenderer.boundedMeasurementProjection(values:[0],gradient:[0],bounds:[(-1,1)],measurement:0.2,allowed:(-0.001)...0.001))
        XCTAssertNil(SpatialRenderer.boundedMeasurementProjection(values:[Double.nan],gradient:[1],bounds:[(-1,1)],measurement:0.2,allowed:(-0.001)...0.001))
    }

    func testSurfaceJacobianMatchesNeutralNodeFiniteDifferences() throws {
        let image = SpatialThumbnail(width:48,height:28,rgb:Array(repeating:0.1,count:48*28*3))
        let map = SurfaceLighting.Map(width:12,height:7,channelEV:Array(repeating:0.2,count:12*7*3),guide:Array(repeating:0.1,count:12*7*3),rowModel:false)
        let footprint = (-2...2).flatMap { dy in (-2...2).map { dx in (x:20.0+Double(dx),y:14.0+Double(dy)) } }
        let jacobian = try XCTUnwrap(SpatialRenderer.surfaceGainJacobian(image:image,map:map,global:0,point:(20,14)))
        for (node,response) in jacobian {
            var plus = map.channelEV,minus = map.channelEV
            for c in 0..<3 { plus[node*3+c] += 0.001;minus[node*3+c] -= 0.001 }
            let a = try XCTUnwrap(SpatialRenderer.sampledSurfaceGain(image:image,map:.init(width:12,height:7,channelEV:plus,guide:map.guide,rowModel:false),global:0,points:footprint,validPixels:Array(footprint.indices)))
            let b = try XCTUnwrap(SpatialRenderer.sampledSurfaceGain(image:image,map:.init(width:12,height:7,channelEV:minus,guide:map.guide,rowModel:false),global:0,points:footprint,validPixels:Array(footprint.indices)))
            XCTAssertEqual(response,(a-b)/0.002,accuracy:0.00002)
        }
    }

    func testRendererFitWeightsConflictingMeasurementsAndRejectsInvalidWeights() throws {
        let image = SpatialThumbnail(width:48,height:28,rgb:Array(repeating:0.1,count:48*28*3))
        let map = SurfaceLighting.Map(width:12,height:7,channelEV:Array(repeating:0,count:12*7*3),guide:Array(repeating:0.1,count:12*7*3),rowModel:false)
        let points = (0..<12).map { (x:20,y:14,delta:$0 < 6 ? 0.08 : -0.08) }
        let weights = (0..<12).map { $0 < 6 ? 1.0 : 0.01 }
        let result = try XCTUnwrap(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0,observations:points,observationWeights:weights))
        var gains = map.channelEV
        for p in result.indices { for c in 0..<3 { gains[p*3+c] += result[p] } }
        let fitted = SurfaceLighting.Map(width:12,height:7,channelEV:gains,guide:map.guide,rowModel:false)
        let light = SpatialRenderer.surfaceRGB([0.1,0.1,0.1],x:20.5/48,y:14.5/28,map:fitted,global:0)
        XCTAssertGreaterThan(log2(light[0]/0.1),0.07)
        XCTAssertNil(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0,observations:points,observationWeights:[1]))
        XCTAssertNil(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0,observations:points,observationWeights:Array(repeating:0,count:12)))
        XCTAssertEqual(fitted.guide,map.guide)
    }

    func testSpatialPriorPropagatesWithinSurfaceAndRespectsBoundary() throws {
        let w = 48,h = 28,mw = 12,mh = 7
        var rgb = [Float](repeating:0.1,count:w*h*3)
        var guide = [Float](repeating:0.1,count:mw*mh*3)
        for y in 0..<h { for x in w/2..<w { for c in 0..<3 { rgb[(y*w+x)*3+c] = 0.7 } } }
        for y in 0..<mh { for x in mw/2..<mw { for c in 0..<3 { guide[(y*mw+x)*3+c] = 0.7 } } }
        let image = SpatialThumbnail(width:w,height:h,rgb:rgb)
        let map = SurfaceLighting.Map(width:mw,height:mh,channelEV:Array(repeating:0,count:mw*mh*3),guide:guide,rowModel:false)
        let points = (0..<12).map { (x:8,y:8+$0%4,delta:0.08) }
        let base = try XCTUnwrap(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0,observations:points))
        let fitted = try XCTUnwrap(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0,observations:points,spatialRegularization:0.1))
        XCTAssertEqual(base[5*mw+4],0)
        XCTAssertGreaterThan(fitted[5*mw+4],0.015)
        XCTAssertLessThan(abs(fitted[5*mw+8]),0.00001)
        let limits = Array(repeating:(lower:-0.02,upper:0.02),count:mw*mh)
        let bounded = try XCTUnwrap(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:0,observations:points,spatialRegularization:0.1,bounds:limits))
        XCTAssertTrue(bounded.allSatisfy { abs($0) <= 0.020001 })
    }

    func testRendererGuidedFitAbstainsWhenHighlightsHaveNoGainResponse() {
        let image = SpatialThumbnail(width:32,height:32,rgb:Array(repeating:0.8,count:32*32*3))
        let map = SurfaceLighting.Map(width:8,height:8,channelEV:Array(repeating:0,count:8*8*3),guide:Array(repeating:0.8,count:8*8*3),rowModel:false)
        var points = [(x:Int,y:Int,delta:Double)]()
        for y in [8,16,24] { for x in [6,10,14,18,22] { points.append((x,y,0.1)) } }
        XCTAssertNil(SpatialRenderer.fitSurfaceIncrements(image:image,map:map,global:1,observations:points))
    }
    func testRegisteredCameraAnchorReducesManufacturedExposureSpikeWithoutChangingSurfaceMaps() throws {
        guard ProcessInfo.processInfo.environment["FRANKLUMA_REGISTERED_ANCHOR"] != "0" else {
            throw XCTSkip("Run with registered-camera validation enabled")
        }
        let w = 96, h = 56
        var seed: UInt64 = 17, rgb: [Float] = []
        for _ in 0..<(w*h) {
            seed = seed &* 6364136223846793005 &+ 1
            let value = Float((seed >> 32)%1000)/5000+0.12
            rgb += [value,value*0.8,value*0.6]
        }
        var shifted: [Float] = []
        for y in 0..<h { for x in 0..<w {
            let p = (max(0,y-2)*w+max(0,x-4))*3
            shifted += Array(rgb[p..<(p+3)])
        } }
        let images = (0..<24).map { SpatialThumbnail(width: w,height: h,rgb: $0.isMultiple(of: 2) ? rgb : shifted) }
        let samples = images.enumerated().map { i,image in
            ExposureSample(time: Double(i)/12,level: log2(0.18),segment: 0,
                           cells: SpatialRenderer.predictedCells(image,global: 0,field: SpatialField()),thumbnail: image)
        }
        let fields = images.map { image -> SpatialField in
            var field = SpatialField()
            field.cameraMotion = true
            field.surface = .init(width: 2,height: 2,channelEV: Array(repeating: 0,count: 12),guide: Array(repeating: 0.18,count: 12))
            return field
        }
        var stops = Array(repeating: 0.0,count: samples.count)
        stops[12] = 0.6
        let input = ExposureCurve(times: samples.map(\.time),stops: stops,spatial: fields)
        let output = SceneBrightness.anchor(samples: samples,curve: input,options: SceneSettings(),measurement: samples)
        // The pre-existing per-frame anchor is bounded at 0.25 EV. The
        // correspondence validator must remove more of this artificial spike.
        XCTAssertLessThan(output.stops[12]+(output.spatial[12].brightnessEV ?? 0),0.25)
        XCTAssertEqual(output.stops,input.stops)
        for i in fields.indices { XCTAssertEqual(output.spatial[i].surface?.channelEV,fields[i].surface?.channelEV) }
        let off = SceneBrightness.anchor(samples: samples,curve: input,options: SceneSettings(strength: 0),measurement: samples)
        XCTAssertNil(off.spatial[12].brightnessEV)
    }
    func testSurfaceGainSamplesStayAtAnalysisPixelCentres() {
        for (w,h) in [(96,56),(48,32)] {
            for (x,y) in [(0,0),(w/2,h/2),(w-1,h-1)] {
                let basis = SpatialRenderer.surfaceBasis(x: (Double(x)+0.5)/Double(w),y: (Double(y)+0.5)/Double(h),width: w,height: h)
                let value = basis.reduce(0) { $0+Double($1.0)*$1.1 }
                XCTAssertEqual(value,Double(y*w+x),accuracy: 0.000001)
                XCTAssertEqual(basis.reduce(0) { $0+$1.1 },1,accuracy: 0.000001)
            }
        }
    }
    func testSurfaceGainsRenderIndependentColourWithoutChangingManualSemantics() throws {
        var field = SpatialField()
        field.surface = SurfaceLighting.Map(width: 2, height: 2,
            channelEV: (0..<4).flatMap { _ in [Float(0.5),Float(-0.25),Float(0)] },
            guide: Array(repeating: 0.2, count: 12))
        let output = render([0.2,0.2,0.2], field: field, manual: 0.1)
        XCTAssertEqual(output[0], Float(0.2*pow(2,0.6)), accuracy: 0.0001)
        XCTAssertEqual(output[1], Float(0.2*pow(2,-0.15)), accuracy: 0.0001)
        XCTAssertEqual(output[2], Float(0.2*pow(2,0.1)), accuracy: 0.0001)
        let decoded = try JSONDecoder().decode(SpatialField.self, from: JSONEncoder().encode(field))
        XCTAssertEqual(decoded.surface?.channelEV, field.surface?.channelEV)
    }

    func testSurfacePredictionMatchesNativeWithAsymmetricVerticalGuideAndGains() throws {
        let w = 96,h = 56
        let rgb = (0..<w*h).flatMap { p -> [Float] in
            let row = p/w
            return row < 20 ? [0.32,0.12,0.06] : row < 40 ? [0.08,0.24,0.11] : [0.05,0.1,0.3]
        }
        let rgba = (0..<w*h).flatMap {p in [rgb[p*3],rgb[p*3+1],rgb[p*3+2],Float(1)]}
        let cs = CGColorSpace(name:CGColorSpace.linearSRGB)!
        let source = CIImage(bitmapData:rgba.withUnsafeBytes {Data($0)},bytesPerRow:w*16,size:CGSize(width:w,height:h),format:.RGBAf,colorSpace:cs)
        let context = CIContext(options:[.workingColorSpace:cs,.cacheIntermediates:false])
        func raster(_ image:CIImage) -> [Float] {
            var pixels = [Float](repeating:0,count:w*h*4)
            pixels.withUnsafeMutableBytes {context.render(image,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:cs)}
            return pixels
        }
        let original = raster(source)
        let thumbnail = SpatialThumbnail(width:w,height:h,rgb:(0..<w*h*3).map {original[($0/3)*4+$0%3]})
        var field = SpatialField()
        let gainRows:[[Float]] = [[0.6,0.3,0.1],[-0.4,-0.2,0.1],[0.2,0.1,-0.3]]
        let guideRows:[[Float]] = [[0.32,0.12,0.06],[0.08,0.24,0.11],[0.05,0.1,0.3]]
        let gains:[Float] = (0..<12).flatMap {gainRows[$0/4]}
        let guides:[Float] = (0..<12).flatMap {guideRows[$0/4]}
        field.surface = .init(width:4,height:3,channelEV:gains,guide:guides)
        for slope in [Float(0),0.15,-0.2] {
        field.surface!.toneEV = Array(repeating:slope,count:12)
        let actual = raster(SpatialRenderer.render(source,global:0.1,field:field))
        let predicted = SpatialRenderer.predictedCells(thumbnail,global:0.1,field:field)
        for row in 0..<14 {for col in 0..<24 {
            var total = 0.0
            for y in row*4..<(row*4+4) {for x in col*4..<(col*4+4) {
                let p = (y*w+x)*4
                total += 0.2126*Double(actual[p])+0.7152*Double(actual[p+1])+0.0722*Double(actual[p+2])
            }}
            XCTAssertEqual(predicted[row*24+col],total/16,accuracy:0.0001,"row \(row), column \(col)")
        }}
        }
    }

    func testToneJacobianMatchesFiniteDifferencesForTransportedFootprint() throws {
        let image=SpatialThumbnail(width:16,height:16,rgb:(0..<256).flatMap { p -> [Float] in
            let y=Float(0.04+Double(p%7)*0.035);return [y,y*0.8,y*0.6]
        })
        var map=SurfaceLighting.Map(width:2,height:2,channelEV:Array(repeating:0.1,count:12),guide:Array(repeating:0.15,count:12))
        map.toneEV=[0.1,-0.15,0.2,-0.1]
        let points=[(x:6.25,y:6.5),(x:7.25,y:6.5),(x:8.25,y:6.5)],valid=[0,1,2]
        let jac=try XCTUnwrap(SpatialRenderer.surfaceGainJacobian(image:image,map:map,global:0.1,point:(7,7),footprint:points,validPixels:valid,toneDerivative:true))
        for (node,derivative) in jac {
            var plus=map,minus=map
            plus.toneEV![node] += 0.001;minus.toneEV![node] -= 0.001
            let a=try XCTUnwrap(SpatialRenderer.sampledSurfaceGain(image:image,map:plus,global:0.1,points:points,validPixels:valid))
            let b=try XCTUnwrap(SpatialRenderer.sampledSurfaceGain(image:image,map:minus,global:0.1,points:points,validPixels:valid))
            XCTAssertEqual(derivative,(a-b)/0.002,accuracy:0.0001)
        }
    }

    func testToneSlopeIsNeutralBoundedAndLegacyMapsBypassIt() throws {
        let guide = Array(repeating:Float(0.18),count:12)
        let base = SurfaceLighting.Map(width:2,height:2,channelEV:Array(repeating:0,count:12),guide:guide)
        let rgb = [0.3,0.12,0.06]
        let unchanged = SpatialRenderer.surfaceRGB(rgb,x:0.4,y:0.6,map:base,global:0)
        XCTAssertEqual(unchanged,rgb)
        var tone = base;tone.toneEV = Array(repeating:-0.3,count:4)
        let after = SpatialRenderer.surfaceRGB(rgb,x:0.4,y:0.6,map:tone,global:0)
        XCTAssertEqual(after[0]/after[1],rgb[0]/rgb[1],accuracy:1e-12)
        XCTAssertEqual(after[2]/after[1],rgb[2]/rgb[1],accuracy:1e-12)
        XCTAssertEqual(SpatialRenderer.surfaceRGB([0,0,0],x:0.4,y:0.6,map:tone,global:0),[0,0,0])
        tone.toneEV = [Float.nan]
        XCTAssertEqual(SpatialRenderer.surfaceRGB(rgb,x:0.4,y:0.6,map:tone,global:0),unchanged)
        let old = try JSONEncoder().encode(base)
        XCTAssertNil(try JSONDecoder().decode(SurfaceLighting.Map.self,from:old).toneEV)
        tone.toneEV = Array(repeating:0.5,count:4)
        var previous = 0.0
        for i in 1...60 {
            let value = Double(i)/100
            let output = SpatialRenderer.surfaceRGB([value,value,value],x:0.4,y:0.6,map:tone,global:0)[0]
            XCTAssertGreaterThanOrEqual(output,previous-1e-12);previous = output
        }
    }

    func testGuidedSurfacePredictionMatchesNativePixelsAcrossAnEdge() {
        let w = 96, h = 56
        let rgb = (0..<(w*h)).flatMap { p -> [Float] in
            p%w < w/2 ? [0.25,0.12,0.08] : [0.08,0.2,0.3]
        }
        let thumbnail = SpatialThumbnail(width: w,height: h,rgb: rgb)
        var field = SpatialField()
        field.surface = .init(width: 4,height: 3,
            channelEV: (0..<12).flatMap { p -> [Float] in p%4 < 2 ? [0.4,0.2,0.1] : [-0.3,-0.1,0.2] },
            guide: (0..<12).flatMap { p -> [Float] in p%4 < 2 ? [0.25,0.12,0.08] : [0.08,0.2,0.3] })
        let rgba = (0..<(w*h)).flatMap { p in [rgb[p*3],rgb[p*3+1],rgb[p*3+2],Float(1)] }
        let cs = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let source = CIImage(bitmapData: rgba.withUnsafeBytes { Data($0) },bytesPerRow: w*16,
            size: CGSize(width: w,height: h),format: .RGBAf,colorSpace: cs)
        let output = SpatialRenderer.render(source,global: 0.1,field: field)
        var pixels = [Float](repeating: 0,count: w*h*4)
        let context = CIContext(options: [.workingColorSpace: cs])
        pixels.withUnsafeMutableBytes { context.render(output,toBitmap: $0.baseAddress!,rowBytes: w*16,
            bounds: source.extent,format: .RGBAf,colorSpace: cs) }
        let predicted = SpatialRenderer.predictedCells(thumbnail,global: 0.1,field: field)
        for row in 0..<14 { for col in 0..<24 {
            var sum = 0.0
            for y in (row*4)..<(row*4+4) { for x in (col*4)..<(col*4+4) {
                let p = (y*w+x)*4
                sum += 0.2126*Double(pixels[p])+0.7152*Double(pixels[p+1])+0.0722*Double(pixels[p+2])
            } }
            XCTAssertEqual(predicted[row*24+col],sum/16,accuracy: 0.0001)
        } }
    }

    func testSurfaceSceneAnchorRemovesWholeShotDriftAndHonoursToggle() {
        let samples = (0..<24).map { i in ExposureSample(time: Double(i)/12,level: log2(0.2),segment: 0,
            cells: Array(repeating: 0.2,count: 336),thumbnail: SpatialThumbnail(width: 24,height: 24,
                rgb: Array(repeating: 0.2,count: 24*24*3))) }
        var field = SpatialField()
        field.surface = .init(width: 2,height: 2,channelEV: Array(repeating: 0.5,count: 12),guide: Array(repeating: 0.2,count: 12))
        let curve = ExposureCurve(times: samples.map(\.time),stops: Array(repeating: 0,count: samples.count),spatial: Array(repeating: field,count: samples.count))
        let anchored = SceneBrightness.anchor(samples: samples,curve: curve,options: SceneSettings(),measurement: samples)
        for field in anchored.spatial {
            XCTAssertEqual(field.brightnessEV ?? 99,-0.5,accuracy: 0.00001)
            XCTAssertEqual(render([0.2,0.2,0.2],field: field)[0],0.2,accuracy: 0.0001)
        }
        let disabled = SceneBrightness.anchor(samples: samples,curve: curve,options: SceneSettings(preserveBrightness: false),measurement: samples)
        XCTAssertNil(disabled.spatial.first?.brightnessEV)
    }
    func testCameraValidationLeavesMissingThumbnailMeasurementsUnsupported() {
        let samples = (0..<24).map { ExposureSample(time: Double($0)/12,level: log2(0.2),segment: 0,cells: Array(repeating: 0.2,count: 336)) }
        var field = SpatialField()
        field.cameraMotion = true
        field.surface = .init(width: 2,height: 2,channelEV: Array(repeating: 0.1,count: 12),guide: Array(repeating: 0.2,count: 12))
        let curve = ExposureCurve(times: samples.map(\.time),stops: Array(repeating: 0,count: samples.count),spatial: Array(repeating: field,count: samples.count))
        let result = SceneBrightness.anchor(samples: samples,curve: curve,options: SceneSettings(),measurement: samples)
        XCTAssertEqual(result.spatial.count,samples.count)
        XCTAssertTrue(result.spatial.allSatisfy { $0.brightnessEV == nil })
        XCTAssertEqual(result.spatial.first?.surface?.channelEV,field.surface?.channelEV)
    }

    func testSteadySurfaceValidationRemovesLocalFlashAndHonoursMotionAndMode() {
        let w = 96, h = 56, rgb = Array(repeating: Float(0.2),count: 96*56*3)
        let thumbnail = SpatialThumbnail(width: w,height: h,rgb: rgb)
        let samples = (0..<24).map { ExposureSample(time: Double($0)/12,level: log2(0.2),segment: 0,
            cells: Array(repeating: 0.2,count: 336),thumbnail: thumbnail) }
        var fields = samples.indices.map { _ -> SpatialField in
            var field = SpatialField()
            field.surface = .init(width: w,height: h,channelEV: Array(repeating: 0,count: rgb.count),guide: rgb)
            return field
        }
        let flash = (0..<(w*h)).flatMap { p in Array(repeating: Float(p%w < 24 ? 0.16 : 0),count: 3) }
        fields[12].surface = .init(width: w,height: h,channelEV: flash,guide: rgb)
        func curve(_ fields: [SpatialField]) -> ExposureCurve {
            ExposureCurve(times: samples.map(\.time),stops: Array(repeating: 0,count: samples.count),spatial: fields)
        }
        let input = curve(fields)
        let corrected = SceneBrightness.anchor(samples: samples,curve: input,options: SceneSettings(mode: .steady),measurement: samples)
        let output = SpatialRenderer.predictedCells(thumbnail,global: 0,field: corrected.spatial[12])
        XCTAssertEqual(output[7*24+3],0.2,accuracy: 0.001)
        XCTAssertEqual(output[7*24+18],0.2,accuracy: 0.001)
        let smooth = SceneBrightness.anchor(samples: samples,curve: input,options: SceneSettings(mode: .smooth),measurement: samples)
        XCTAssertEqual(smooth.spatial[12].surface?.channelEV,flash)
        fields[12].alignments = [.init(reference: 11,dx: 1,dy: 0,error: 0,accepted: true)]
        let moving = SceneBrightness.anchor(samples: samples,curve: curve(fields),options: SceneSettings(mode: .steady),measurement: samples)
        XCTAssertEqual(moving.spatial[12].surface?.channelEV,flash)
        let disabled = SceneBrightness.anchor(samples: samples,curve: input,options: SceneSettings(mode: .steady,preserveBrightness: false),measurement: samples)
        XCTAssertEqual(disabled.spatial[12].surface?.channelEV,flash)
    }

    private func render(_ rgb: [Float], field: SpatialField?, global: Double = 0, manual: Double = 0, diagnostic: PreviewMode = .corrected) -> [Float] {
        let cs=CGColorSpace(name:CGColorSpace.linearSRGB)!
        let source=CIImage(color:CIColor(red:CGFloat(rgb[0]),green:CGFloat(rgb[1]),blue:CGFloat(rgb[2]),alpha:1,colorSpace:cs)!).cropped(to:CGRect(x:0,y:0,width:16,height:16))
        let context=CIContext(options:[.workingColorSpace:cs])
        let output=SpatialRenderer.render(source,global:global,field:field,diagnostic:diagnostic,manualEV:manual)
        var pixels=[Float](repeating:0,count:16*16*4)
        pixels.withUnsafeMutableBytes { context.render(output,toBitmap:$0.baseAddress!,rowBytes:16*16,bounds:source.extent,format:.RGBAf,colorSpace:cs) }
        return Array(pixels[(8*16+8)*4..<(8*16+8)*4+3])
    }
    func testSurfaceDiagnosticReportsRenderedBrightnessIncludingManualTrim() {
        var field = SpatialField()
        field.surface = .init(width: 2,height: 2,channelEV: (0..<4).flatMap { _ in [Float(0.5),0,0] },guide: Array(repeating: 0.2,count: 12))
        let corrected = render([0.2,0.2,0.2],field: field,manual: 0.2)
        let light = 0.2126*Double(corrected[0])+0.7152*Double(corrected[1])+0.0722*Double(corrected[2])
        let ev = log2(light/0.2)
        // Core Image uses half precision internally; compare within one half-float step.
        let diagnostic = render([0.2,0.2,0.2],field: field,manual: 0.2,diagnostic: .field)
        XCTAssertEqual(Double(diagnostic[0]),ev,accuracy: 0.001)
        XCTAssertEqual(Double(diagnostic[1]),1-ev,accuracy: 0.001)
    }
    func testSceneBrightnessAnchorChecksActualToneOutputAndLeavesManualOverride() {
        let levels = (0..<40).map { $0.isMultiple(of: 2) ? 0.22 : 0.22 * pow(2, 0.6) }
        let samples = levels.enumerated().map { i, light in
            ExposureSample(time: Double(i)/12, level: log2(light), segment: 0,
                cells: Array(repeating: light, count: 336),
                thumbnail: SpatialThumbnail(width: 24, height: 14, rgb: Array(repeating: Float(light), count: 1008)))
        }
        var field = SpatialField()
        field.offsets = Array(repeating: 0.15, count: 54)
        field.exposureStops = Array(repeating: 0.3, count: 54)
        let unanchored = ExposureCurve(times: samples.map(\.time), stops: Array(repeating: 0.4, count: 40), spatial: Array(repeating: field, count: 40))
        let anchored = SceneBrightness.anchor(samples: samples, curve: unanchored, options: SceneSettings(mode: .steady), measurement: samples)
        let expected = 0.22 * pow(2, 0.3)
        for i in samples.indices {
            let rgb = [Float](repeating: Float(levels[i]), count: 3)
            let output = render(rgb, field: anchored.spatial[i], global: anchored.stops[i])
            XCTAssertEqual(Double(output[0]), expected, accuracy: 0.001)
            XCTAssertEqual(render(rgb, field: anchored.spatial[i], global: anchored.stops[i], manual: 0.25)[0], output[0] * Float(pow(2,0.25)), accuracy: 0.001)
        }
        let disabled = SceneBrightness.anchor(samples: samples, curve: unanchored, options: SceneSettings(preserveBrightness: false), measurement: samples)
        XCTAssertEqual(disabled.stops, unanchored.stops)
        XCTAssertNil(disabled.spatial[0].brightnessEV)
        let zero = SceneBrightness.anchor(samples: samples, curve: unanchored, options: SceneSettings(strength: 0), measurement: samples)
        XCTAssertNil(zero.spatial[0].brightnessEV)
    }

    func testCombinedValidationFieldMatchesNativePixelsForPositiveAndNegativeEV() {
        for value in [-0.3, 0.0, 0.3] {
            var field = SpatialField()
            field.brightnessEV = -0.1
            field.validationStops = Array(repeating: value, count: 54)
            field.stops = Array(repeating: 0.1, count: 54)
            field.exposureStops = Array(repeating: 0.2, count: 54)
            field.offsets = Array(repeating: 0.01, count: 54)
            let rgb: [Float] = [0.2,0.21,0.19]
            let thumbnail = SpatialThumbnail(width: 24, height: 14, rgb: (0..<336).flatMap { _ in rgb })
            let cells = SpatialRenderer.predictedCells(thumbnail, global: 0.3, field: field)
            let output = render(rgb, field: field, global: 0.3)
            let light = 0.2126*Double(output[0])+0.7152*Double(output[1])+0.0722*Double(output[2])
            XCTAssertEqual(cells[0], light, accuracy: 0.0001)
        }
    }

    func testBrightnessSafeguardBoundsToneOvershootBeforeManualAdjustment() {
        var field = SpatialField()
        field.offsets = Array(repeating: 0.8, count: 54)
        field.brightnessEV = 0
        let output = render([0.2,0.2,0.2], field: field)
        XCTAssertEqual(output[0], 0.2 * Float(pow(2,0.5)), accuracy: 0.001)
        let thumbnail = SpatialThumbnail(width: 24, height: 14, rgb: Array(repeating: 0.2, count: 1008))
        let prediction = SpatialRenderer.predictedCells(thumbnail, global: 0, field: field)
        XCTAssertEqual(prediction[0], Double(output[0]), accuracy: 0.001)
    }

    func testManualExposureScalesAutomaticToneAndPreservesHighlightSafety() {
        var field = SpatialField()
        field.offsets = Array(repeating: 0.05, count: 54)
        let input: [Float] = [0.2, 0.2, 0.2]
        let automatic = render(input, field: field)
        let manual = render(input, field: field, manual: 1)
        for c in 0..<3 { XCTAssertEqual(manual[c], automatic[c] * 2, accuracy: 0.001) }
        let bright = render([0.96, 0.95, 0.94], field: field, manual: 2)
        XCTAssertLessThanOrEqual(bright.max()!, 0.996)
        let noField = render([0.96, 0.95, 0.94], field: nil, manual: 2)
        XCTAssertLessThanOrEqual(noField.max()!, 0.996)
        XCTAssertEqual(render([0.05, 0.05, 0.05], field: SpatialField(), global: 2, manual: 1)[0], 0.4, accuracy: 0.001)
    }

    func testManualExposurePreservesSourcePixelDetailWithoutNeighbourBlending() {
        let cs = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let pixels: [Float] = (0..<256).flatMap { i in
            let value: Float = i.isMultiple(of: 2) ? 0.1 : 0.6
            return [value, value * 0.5, value * 0.25, 1]
        }
        let data = pixels.withUnsafeBytes { Data($0) }
        let source = CIImage(bitmapData: data, bytesPerRow: 16 * 16, size: CGSize(width: 16, height: 16), format: .RGBAf, colorSpace: cs)
        let image = SpatialRenderer.render(source, global: 0, field: nil, manualEV: -1)
        let context = CIContext(options: [.workingColorSpace: cs])
        var output = [Float](repeating: 0, count: pixels.count)
        output.withUnsafeMutableBytes {
            context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16 * 16, bounds: source.extent, format: .RGBAf, colorSpace: cs)
        }
        for i in 0..<256 {
            for channel in 0..<3 { XCTAssertEqual(output[i * 4 + channel], pixels[i * 4 + channel] * 0.5, accuracy: 0.0001) }
        }
    }
    func testToneCorrectionPreservesBlackAndSaturatedColour() {
        var field=SpatialField()
        field.offsets=Array(repeating:0.15,count:54)
        for colour: [Float] in [[0,0,0],[0.01,0.01,0.01],[0.6,0.25,0.03]] {
            let output=render(colour,field:field)
            for c in 0..<3 { XCTAssertEqual(output[c],colour[c],accuracy:0.001) }
        }
        let neutral=render([0.3,0.3,0.3],field:field)
        XCTAssertEqual(neutral[0],0.45,accuracy:0.001)
    }
    func testToneCorrectionPreservesLinearChromaticityAndHighlights() {
        var field=SpatialField()
        field.offsets=Array(repeating:0.15,count:54)
        let input: [Float]=[0.32,0.30,0.29]
        let output=render(input,field:field)
        XCTAssertEqual(output[0]/output[1],input[0]/input[1],accuracy:0.001)
        XCTAssertEqual(output[2]/output[1],input[2]/input[1],accuracy:0.001)
        let bright=render([0.96,0.95,0.94],field:field)
        XCTAssertLessThanOrEqual(bright.max()!,0.996)
    }

    func testPatchColourMapsCannotReshapeSubjectTexture() {
        var field = SpatialField()
        field.stops = Array(repeating: log2(0.7), count: 54)
        field.exposureStops = Array(repeating: log2(0.9), count: 54)
        field.offsets = Array(repeating: 0.015, count: 54)
        let colours: [[Float]] = [[0.16,0.025,0.012], [0.3,0.29,0.28], [0.6,0.25,0.03]]
        let expected = colours.map { render($0, field: field) }
        // Stale or changing patch fits must not introduce colour-selected
        // contrast changes inside the smooth coarse correction field.
        field.patchTone = SpatialPatchTone(stops: Array(repeating: log2(0.5), count: 336),
            offsets: Array(repeating: 0.08, count: 336),
            red: Array(repeating: 0.5, count: 336), green: Array(repeating: 0.3, count: 336),
            confidence: Array(repeating: 1, count: 336))
        for (index, colour) in colours.enumerated() {
            let output = render(colour, field: field)
            for channel in 0..<3 { XCTAssertEqual(output[channel], expected[index][channel], accuracy: 0.001) }
        }
    }
}
