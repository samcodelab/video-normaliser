import XCTest
@testable import FrankLuma

final class PulseFieldCompositionTests: XCTestCase {
    func testSupplementReducesResidualOnWiderOnlyLightingEvent() throws {
        let w = 96,h = 56,levels = [0.0,0.2,0.4,0.31,0.18,0.08,0]
        let base = (0..<w*h*3).map { Float(0.07+Double(($0*173+31)%997)/997*0.13) }
        let images = levels.map { level in SpatialThumbnail(width:w,height:h,rgb:base.map { $0*Float(exp2(level)) }) }
        let samples = images.enumerated().map { ExposureSample(time:Double($0.offset)/12,level:0,segment:0,thumbnail:$0.element) }
        let fields = images.enumerated().map { frame,image -> SpatialField in
            var field = SpatialField()
            field.surface = .init(width:w,height:h,channelEV:Array(repeating:Float(-levels[frame]+(frame == 3 ? 0.08 : 0)),count:w*h*3),guide:image.rgb,rowModel:false)
            return field
        }
        let options = SceneSettings(strength:1,radius:0.5,mode:.smooth,spatialStrength:1)
        let adjacent = TrackedSurfaceResidual.applyPulseComposition(samples:samples,stops:Array(repeating:0,count:7),
            fields:fields,options:options,maximumPasses:3,anchorBoundaries:true,multiInterval:false)
        let supplemented = TrackedSurfaceResidual.applyPulseComposition(samples:samples,stops:Array(repeating:0,count:7),
            fields:fields,options:options,maximumPasses:3,anchorBoundaries:true,multiInterval:true,supplemental:true)
        func residual(_ maps: [SpatialField]) -> Double {
            var original = 0.0,corrected = 0.0
            for y in 20...24 { for x in 45...49 {
                let p = (y*w+x)*3,weights = [0.2126,0.7152,0.0722]
                let rgb = SpatialRenderer.surfaceRGB((0..<3).map { Double(images[3].rgb[p+$0]) },
                    x:(Double(x)+0.5)/Double(w),y:(Double(y)+0.5)/Double(h),map:maps[3].surface!,global:0)
                for c in 0..<3 { original += weights[c]*Double(base[p+c]);corrected += weights[c]*rgb[c] }
            } }
            return abs(log2(corrected/original))
        }
        XCTAssertLessThan(residual(supplemented),residual(adjacent)*0.9)
        for i in fields.indices {
            XCTAssertEqual(supplemented[i].surface?.guide,fields[i].surface?.guide)
            for (a,b) in zip(supplemented[i].surface!.channelEV,fields[i].surface!.channelEV) {
                XCTAssertLessThanOrEqual(abs(Double(a)-Double(b)),0.2500001)
            }
        }
    }
    func testThreeFrameSceneKeepsUnavailableWiderIntervalDisabled() {
        let w = 96,h = 56
        let rgb = (0..<w*h*3).map { Float(0.07+Double(($0*173+31)%997)/997*0.13) }
        let image = SpatialThumbnail(width:w,height:h,rgb:rgb)
        let samples = (0..<3).map { ExposureSample(time:Double($0)/12,level:0,segment:0,thumbnail:image) }
        var field = SpatialField()
        field.surface = .init(width:w,height:h,channelEV:Array(repeating:0,count:w*h*3),guide:rgb,rowModel:false)
        let fields = Array(repeating:field,count:3)
        let result = TrackedSurfaceResidual.applyPulseComposition(samples:samples,stops:[0,0,0],fields:fields,
            options:SceneSettings(strength:1,radius:0.5,mode:.smooth,spatialStrength:1))
        XCTAssertEqual(result.map { $0.surface?.channelEV },fields.map { $0.surface?.channelEV })
    }
    func testQuietDonorsDoNotAuthorizeIsolatedStrongSourceChange() throws {
        let w = 96, h = 56, x = 49, y = 25
        let base: [Float] = (0..<w*h*3).map { Float(0.07+Double(($0*173+31)%997)/997*0.13) }
        var changed = base
        for yy in y-2...y+2 { for xx in x-2...x+2 { for c in 0..<3 {
            changed[(yy*w+xx)*3+c] *= Float(exp2(0.2))
        } } }
        let images = [base,changed,base].map { SpatialThumbnail(width:w,height:h,rgb:$0) }
        XCTAssertGreaterThan(try XCTUnwrap(SurfaceTracking.cameraShapeCorrelation(images[1],images[0],
            x:x,y:y,referenceX:x,referenceY:y)),0.95)
        let samples = images.enumerated().map { ExposureSample(time:Double($0.offset)/12,
            level:0,segment:0,thumbnail:$0.element) }
        var tracks = [TrackedSurfaceResidual.Track]()
        for yy in stride(from:7,to:h-7,by:6) { for xx in stride(from:7,to:w-7,by:6) {
            tracks.append(.init(identity:[],identityHalf:6,observations:(0..<3).map {
                .init(frame:$0,x:xx,y:yy,level:0)
            }))
        } }
        var authorized = false, quietOtherQueries = 0
        TrackedSurfaceResidual.pulseDiagnostics(samples:samples,images:images,tracks:tracks,cameraGuided:true,
            certified:{ points,_,_ in
                if points[1].x == x && points[1].y == y { authorized = true }
                else { quietOtherQueries += 1 }
            })
        XCTAssertGreaterThan(quietOtherQueries,12)
        XCTAssertFalse(authorized)
    }

    func testRepeatedCalibrationReducesOpposingLocalErrorsWithinTotalLimit() throws {
        let w = 96, h = 56, n = 5
        let base: [Float] = (0..<w*h*3).map { Float(0.07+Double(($0*173+31)%997)/997*0.13) }
        let images = (0..<n).map { frame in SpatialThumbnail(width:w,height:h,
            rgb:base.enumerated().map { p,value in
                value*Float(exp2(frame == 2 ? ((p/3)%w < w/2 ? 0.2 : 0.4) : 0))
            }) }
        let samples = images.enumerated().map { ExposureSample(time:Double($0.offset)/12,
            level:0,segment:0,thumbnail:$0.element) }
        let fields = images.enumerated().map { frame,image -> SpatialField in
            var field = SpatialField()
            field.surface = .init(width:w,height:h,
                channelEV:[Float](repeating:frame == 2 ? -0.3 : 0,count:w*h*3),guide:image.rgb,rowModel:false)
            return field
        }
        let options = SceneSettings(strength:1,radius:0.5,mode:.smooth,spatialStrength:1)
        let single = TrackedSurfaceResidual.applyPulseComposition(samples:samples,
            stops:[Double](repeating:0,count:n),fields:fields,options:options,maximumPasses:1,anchorBoundaries:true)
        let repeated = TrackedSurfaceResidual.applyPulseComposition(samples:samples,
            stops:[Double](repeating:0,count:n),fields:fields,options:options,maximumPasses:3,anchorBoundaries:true)
        func energy(_ maps: [SpatialField]) -> Double {
            var energy = 0.0
            for center in [22,73] {
                var levels = [Double]()
                for frame in 1...3 {
                    var light = 0.0
                    for y in 20...24 { for x in center-2...center+2 {
                        let p = (y*w+x)*3
                        let rgb = SpatialRenderer.surfaceRGB((0..<3).map { Double(images[frame].rgb[p+$0]) },
                            x:(Double(x)+0.5)/Double(w),y:(Double(y)+0.5)/Double(h),map:maps[frame].surface!,global:0)
                        light += 0.2126*rgb[0]+0.7152*rgb[1]+0.0722*rgb[2]
                    } }
                    levels.append(log2(light/25))
                }
                let error = levels[1]-(levels[0]+levels[2])/2
                energy += error*error
            }
            return energy
        }
        XCTAssertLessThan(energy(single),energy(fields))
        XCTAssertLessThan(energy(repeated),energy(single))
        for i in 0..<n {
            XCTAssertEqual(repeated[i].surface?.guide,fields[i].surface?.guide)
            for (after,before) in zip(repeated[i].surface!.channelEV,fields[i].surface!.channelEV) {
                XCTAssertLessThanOrEqual(abs(Double(after)-Double(before)),0.2500001)
            }
        }
        XCTAssertEqual(repeated[0].surface?.channelEV,fields[0].surface?.channelEV)
        XCTAssertEqual(repeated[4].surface?.channelEV,fields[4].surface?.channelEV)
    }

    func testRenderedOvercorrectionIsReducedWithoutChangingGeometry() throws {
        let w = 96, h = 56, n = 9
        // Deterministic textured source, with a real source flash of 0.2 EV.
        let base: [Float] = (0..<w*h*3).map { i in
            Float(0.07+Double((i*173+31)%997)/997*0.13)
        }
        let images = (0..<n).map { frame in SpatialThumbnail(width:w,height:h,
            rgb:base.map { $0*Float(exp2(frame == 4 ? 0.2 : 0)) }) }
        let samples = images.enumerated().map { ExposureSample(time:Double($0.offset)/12,
            level:0,segment:0,thumbnail:$0.element) }
        let fields = images.enumerated().map { frame,image -> SpatialField in
            var field = SpatialField()
            field.surface = .init(width:w,height:h,
                channelEV:[Float](repeating:frame == 4 ? -0.3 : 0,count:w*h*3),guide:image.rgb,rowModel:false)
            return field
        }
        let options = SceneSettings(strength:1,radius:0.5,mode:.smooth,spatialStrength:1)
        let result = TrackedSurfaceResidual.applyPulseComposition(samples:samples,
            stops:[Double](repeating:0,count:n),fields:fields,options:options)
        func level(_ frame: Int,_ maps: [SpatialField]) -> Double {
            var sum = 0.0
            // Source-selected central patch avoids the unsupported outer border.
            for y in 20...24 { for x in 44...48 {
                let p = (y*w+x)*3
                let rgb = SpatialRenderer.surfaceRGB((0..<3).map { Double(images[frame].rgb[p+$0]) },
                    x:(Double(x)+0.5)/Double(w),y:(Double(y)+0.5)/Double(h),
                    map:maps[frame].surface!,global:0)
                sum += 0.2126*rgb[0]+0.7152*rgb[1]+0.0722*rgb[2]
            } }
            return log2(sum/25)
        }
        let before = level(4,fields)-(level(3,fields)+level(5,fields))/2
        let after = level(4,result)-(level(3,result)+level(5,result))/2
        XCTAssertLessThan(abs(after),abs(before)*0.5)
        for i in 0..<n {
            XCTAssertEqual(result[i].surface?.guide,fields[i].surface?.guide)
            XCTAssertEqual(result[i].surface?.width,w)
            XCTAssertEqual(result[i].surface?.height,h)
        }
    }
}
