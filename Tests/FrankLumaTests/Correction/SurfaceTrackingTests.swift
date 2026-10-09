import XCTest
@testable import FrankLuma

final class SurfaceTrackingTests: XCTestCase {
    func testEventCentredTrackStopsAtCutsAndRecoversAfterEarlierOcclusion() {
        let w = 32,h = 24
        var seed:UInt64 = 42
        let rgb:[Float] = (0..<w*h*3).map { _ in
            seed = seed &* 6364136223846793005 &+ 1
            return 0.08+Float((seed >> 32)%1000)/10000
        }
        let visible = SurfaceTracking.Prepared(.init(width:w,height:h,rgb:rgb))
        let hidden = SurfaceTracking.Prepared(.init(width:w,height:h,rgb:Array(repeating:0.12,count:rgb.count)))
        let frames = [hidden,visible,visible,visible,visible]
        let track = SurfaceTracking.trajectoryThrough(frames,segments:[0,0,0,0,0],anchor:3,x:16,y:12)
        XCTAssertEqual(track.map(\.frame),[1,2,3,4])
        XCTAssertTrue(track.allSatisfy {$0.x == 16 && $0.y == 12 && $0.confidence > 0})
        XCTAssertEqual(SurfaceTracking.trajectoryThrough(frames,segments:[0,0,0,1,1],anchor:3,x:16,y:12).map(\.frame),[3,4])
        XCTAssertTrue(SurfaceTracking.trajectoryThrough(frames,segments:[0],anchor:3,x:16,y:12).isEmpty)
    }

    func testEventCentredTrackPreservesCoordinatesAndRGBUnderTranslation() throws {
        let w = 40,h = 32
        var seed:UInt64 = 719
        let source:[Float] = (0..<w*h*3).map { _ in
            seed = seed &* 6364136223846793005 &+ 1
            return 0.08+Float((seed >> 32)%1000)/10000
        }
        let frames = (0..<5).map { frame -> SurfaceTracking.Prepared in
            let rgb = (0..<w*h*3).map { p -> Float in
                let x = (p/3)%w,y = (p/3)/w,c = p%3
                return source[(y*w+max(0,x-frame))*3+c]*Float(exp2(Double(frame)*0.1*Double(c+1)))
            }
            return .init(.init(width:w,height:h,rgb:rgb))
        }
        let track = SurfaceTracking.trajectoryThrough(frames,segments:Array(repeating:0,count:5),anchor:2,x:20,y:16,radius:3)
        XCTAssertEqual(track.map(\.frame),[0,1,2,3,4])
        for point in track {
            XCTAssertEqual(point.x,18+point.frame)
            XCTAssertEqual(point.y,16)
            for c in 0..<3 {
                XCTAssertEqual(point.channelLevels[c]-track[0].channelLevels[c],Double(point.frame)*0.1*Double(c+1),accuracy:1e-6)
            }
        }
    }

    func testDenseMeasurementTransportRetainsExposureAndRejectsBadCorrespondence() throws {
        let w = 48,h = 36
        func pixel(_ x: Int,_ y: Int,_ c: Int) -> Float {
            Float(0.13+0.025*sin(Double(x)*0.7)+0.02*cos(Double(y)*0.6)+Double(c)*0.01)
        }
        let source = SpatialThumbnail(width:w,height:h,rgb:(0..<w*h*3).map { pixel(($0/3)%w,($0/3)/w,$0%3) })
        let reference = SpatialThumbnail(width:w,height:h,rgb:(0..<w*h*3).map { pixel(($0/3)%w-1,($0/3)/w,$0%3)*1.2 })
        let forward = (0..<w*h).flatMap { _ in [Float(1),Float(0)] },backward = forward.map { -$0 }
        let flow = SurfaceMotion.Flow(width:w,height:h,forward:forward,backward:backward)
        let measured = try XCTUnwrap(SurfaceTracking.flowTransportedPixels(source,reference,flow:flow,x:24,y:18))
        XCTAssertEqual(measured.maximumDisplacement,1,accuracy:1e-10)
        var expected = [Double]()
        for y in 16...20 { for x in 22...26 { for c in 0..<3 { expected.append(Double(pixel(x,y,c)*1.2)) } } }
        XCTAssertEqual(measured.pixels,expected)
        let inconsistent = SurfaceMotion.Flow(width:w,height:h,forward:forward,backward:Array(repeating:0,count:forward.count))
        XCTAssertNil(SurfaceTracking.flowTransportedPixels(source,reference,flow:inconsistent,x:24,y:18))
        XCTAssertNil(SurfaceTracking.flowTransportedPixels(source,reference,flow:flow,x:24,y:18,maximumDisplacement:0.5))
        let flat = SpatialThumbnail(width:w,height:h,rgb:Array(repeating:0.1,count:w*h*3))
        XCTAssertNil(SurfaceTracking.flowTransportedPixels(flat,flat,flow:flow,x:24,y:18))
        // Metering can change the sampled radiance, but cannot supply geometry.
        let metered = try XCTUnwrap(SurfaceTracking.flowTransportedPixels(source,reference,flow:flow,x:24,y:18,measurementReference:flat))
        XCTAssertEqual(metered.pixels,Array(repeating:Double(Float(0.1)),count:75))
        XCTAssertEqual(metered.maximumDisplacement,measured.maximumDisplacement)
        XCTAssertEqual(metered.points.map { $0.x },measured.points.map { $0.x })
        XCTAssertEqual(metered.points.map { $0.y },measured.points.map { $0.y })
        XCTAssertNil(SurfaceTracking.flowTransportedPixels(flat,flat,flow:flow,x:24,y:18,measurementReference:reference))
        XCTAssertNil(SurfaceTracking.flowTransportedPixels(source,reference,flow:inconsistent,x:24,y:18,measurementReference:flat))
        let wrongSize = SpatialThumbnail(width:1,height:1,rgb:[0.1,0.1,0.1])
        XCTAssertNil(SurfaceTracking.flowTransportedPixels(source,reference,flow:flow,x:24,y:18,measurementReference:wrongSize))
    }

    func testUnsupportedEvidenceCannotChangeSharedPowerDurationOrMaterialDonors() throws {
        let supported: [(delta: [Double], confidence: Double)] = [([0.2,0.1,0.3],1),([0.4,0.3,0.5],1)]
        XCTAssertEqual(SurfaceLighting.supportedCommonDelta(supported),SurfaceLighting.supportedCommonDelta(supported+Array(repeating: ([9,-9,8],0),count: 20)))
        let reliable = (0..<8).map { SurfaceTracking.Observation(frame: $0,x: 0,y: 0,channelLevels: [-2,-2,-2],confidence: 1) }
        let unsupported = (8..<24).map { SurfaceTracking.Observation(frame: $0,x: 0,y: 0,channelLevels: [8,-8,9],confidence: 0) }
        XCTAssertEqual(SurfaceLighting.supportedTrajectoryWeight(reliable),SurfaceLighting.supportedTrajectoryWeight(reliable+unsupported))
        let points = [1,2].map { SurfaceTracking.LightingEstimate(frame: 0,x: $0,y: 0,channelEV: [0.3,0.3,0.3],confidence: 1) }
        let poisoned = points+[.init(frame: 0,x: 0,y: 0,channelEV: [9,9,9],confidence: 0)]
        XCTAssertEqual(SurfaceLighting.supportedIlluminationPower(points,global: [0],strength: 1),SurfaceLighting.supportedIlluminationPower(poisoned,global: [0],strength: 1))
        let rgb: [Float] = [0.2,0.2,0.2]+Array(repeating: [Float(0.24),0.2,0.2],count: 7).flatMap { $0 }
        let before = try XCTUnwrap(SurfaceLighting.materialConsensus(SurfaceLighting.materialDonors(points,rgb: rgb,pixel: 0,channel: 0,width: 8,height: 1)))
        let after = try XCTUnwrap(SurfaceLighting.materialConsensus(SurfaceLighting.materialDonors(poisoned,rgb: rgb,pixel: 0,channel: 0,width: 8,height: 1)))
        XCTAssertEqual(before.ev,after.ev);XCTAssertEqual(before.reliability,after.reliability)
    }

    func testKnownPanLocalFlashSeparatesCorrespondenceFromGlobalLightAgreement() throws {
        let w = 40,h = 32
        var seed: UInt64 = 912,rgb = [Float]()
        for _ in 0..<(w*h) {
            seed = seed &* 6364136223846793005 &+ 1
            let level = Float((seed >> 32)%1000)/10000+0.08
            rgb += [level,level*0.8,level*0.6]
        }
        let a = SurfaceTracking.Prepared(.init(width: w,height: h,rgb: rgb))
        for exposure in [[0.0,0.0,0.0],[0.25,0.25,0.25],[0.5,0.5,0.5],[0.4,-0.3,0.2]] {
            var translated = rgb
            for y in 0..<h { for x in 0..<w { for c in 0..<3 {
                translated[(y*w+x)*3+c] = rgb[(y*w+max(0,x-2))*3+c]*Float(pow(2,exposure[c]))
            } } }
            let b = SurfaceTracking.Prepared(.init(width: w,height: h,rgb: translated))
            let match = try XCTUnwrap(SurfaceTracking.match(a,b,x: 20,y: 16,radius: 3))
            XCTAssertEqual(match.x,22);XCTAssertEqual(match.y,16)
            XCTAssertGreaterThan(match.confidence*match.photometricConfidence,0.95)
            for c in 0..<3 { XCTAssertEqual(match.channelEV[c],exposure[c],accuracy: 0.00001) }
            let point = SurfaceTracking.Observation(frame: 0,x: 20,y: 16,channelLevels: [-2,-2,-2],confidence: 1)
            XCTAssertEqual(SurfaceTracking.localMeasurementIdentity(a,b,point: point,match: match),1)
            let wrongFootprint = SurfaceTracking.Match(x: 23,y: 16,channelEV: match.channelEV,error: 0,confidence: 1)
            XCTAssertEqual(SurfaceTracking.localMeasurementIdentity(a,b,point: point,match: wrongFootprint),0)
            let sharedAgreement = SurfaceLighting.motionPhotometricConfidence(delta: match.channelEV,common: [0,0,0])
            // Characterize the existing bottleneck: perfect surface identity
            // and a valid local exposure measurement can fail the global gate.
            if exposure[0] == 0.5 || exposure[1] < 0 { XCTAssertLessThan(sharedAgreement,0.15) }
            print("LOCAL_FLASH_GATE exposure=\(exposure) correspondence=\(match.confidence*match.photometricConfidence) sharedAgreement=\(sharedAgreement)")
        }
    }

    func testNativeFlowGuidanceRecoversDisplacementWithoutNormalisingMeasuredExposure() throws {
        let w = 128,h = 96
        var seed: UInt64 = 719,rgb = [Float]()
        for _ in 0..<(w*h) {
            seed = seed &* 6364136223846793005 &+ 1
            let value = Float((seed >> 32)%1000)/10000+0.08
            rgb += [value,value*0.8,value*0.6]
        }
        var translated = rgb
        let exposure = [0.4,-0.3,0.2]
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            translated[(y*w+x)*3+c] = rgb[(max(0,y-1)*w+max(0,x-2))*3+c]*Float(pow(2,exposure[c]))
        } } }
        let source = SpatialThumbnail(width: w,height: h,rgb: rgb)
        let reference = SpatialThumbnail(width: w,height: h,rgb: translated)
        let flow = try XCTUnwrap(SurfaceMotion.opticalFlow(source,reference))
        let predicted = try XCTUnwrap(flow.prediction(64,48))
        XCTAssertEqual(predicted.0,66,accuracy: 0.25);XCTAssertEqual(predicted.1,49,accuracy: 0.25)
        let compact = try XCTUnwrap(flow.coarseGuidance(width: w/2,height: h/2))
        let compactPrediction = try XCTUnwrap(compact.prediction(32,24))
        XCTAssertEqual(compactPrediction.0,33,accuracy: 0.125)
        XCTAssertEqual(compactPrediction.1,24.5,accuracy: 0.125)
        let restored = try JSONDecoder().decode(SurfaceMotion.Flow.self,from: JSONEncoder().encode(compact))
        XCTAssertEqual(try XCTUnwrap(restored.prediction(32,24)).0,compactPrediction.0,accuracy: 0.000001)
        let legacy = try JSONDecoder().decode(SpatialThumbnail.self,from: Data("{\"width\":1,\"height\":1,\"rgb\":[0.2,0.2,0.2]}".utf8))
        XCTAssertNil(legacy.previousFlow)
        let a = SurfaceTracking.Prepared(source),b = SurfaceTracking.Prepared(reference)
        XCTAssertNil(SurfaceTracking.match(a,b,x: 64,y: 48,radius: 0))
        let match = try XCTUnwrap(SurfaceTracking.match(a,b,x: 64,y: 48,radius: 0,flow: flow))
        XCTAssertEqual(match.x,66);XCTAssertEqual(match.y,49)
        for c in 0..<3 { XCTAssertEqual(match.channelEV[c],exposure[c],accuracy: 0.00001) }
        // A prediction without a matching reverse displacement must not guide
        // correspondence, even when the forward field points at the right area.
        let inconsistent = SurfaceMotion.Flow(width: w,height: h,forward: flow.forward,
            backward: Array(repeating: 0,count: flow.backward.count))
        XCTAssertNil(SurfaceTracking.match(a,b,x: 64,y: 48,radius: 0,flow: inconsistent))
    }

    func testStationaryContrastIdentityRetainsColourExposureButRejectsChangedTexture() {
        let w = 32,h = 24
        var seed: UInt64 = 819,rgb = [Float]()
        for _ in 0..<(w*h) {
            seed = seed &* 6364136223846793005 &+ 1
            let level = Float((seed >> 32)%1000)/10000+0.08
            rgb += [level,level*0.8,level*0.6]
        }
        let source = SpatialThumbnail(width: w,height: h,rgb: rgb)
        let exposure = SpatialThumbnail(width: w,height: h,rgb: rgb.enumerated().map {
            $0.element*Float(pow(2,[0.4,-0.3,0.2][$0.offset%3]))
        })
        XCTAssertEqual(SurfaceTracking.stationaryContrastConfidence(source,exposure,x: 15,y: 12),0.65,accuracy: 0.00001)
        var translated = rgb
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            translated[(y*w+x)*3+c] = rgb[(y*w+max(0,x-1))*3+c]
        } } }
        XCTAssertEqual(SurfaceTracking.stationaryContrastConfidence(source,
            SpatialThumbnail(width: w,height: h,rgb: translated),x: 15,y: 12),0)
    }

    func testUnsupportedMeasurementsCannotContaminateJointSurfaceTargets() {
        let times = (0..<20).map { Double($0)/12 }
        let unsupported = 4...8
        func tracks(_ altered: Bool) -> [[SurfaceTracking.Observation]] {
            (0..<3).map { index in times.indices.map { i in
                let level = -3.0-Double(index)*0.2+0.3*sin(Double(i)*0.7)+(altered && unsupported.contains(i) ? 2 : 0)
                return .init(frame: i,x: 4+index*8,y: 12,channelLevels: [level,level,level],confidence: unsupported.contains(i) ? 0 : 1,
                    sourcePeakLevel: altered && unsupported.contains(i) ? 0 : level)
            } }
        }
        let clean = SurfaceLighting.jointLighting(tracks(false),times: times,radius: 0.5,mode: .smooth,
            strength: 1,global: [],shortTracks: false,shortGraph: false,confidenceTargets: true)
        let altered = SurfaceLighting.jointLighting(tracks(true),times: times,radius: 0.5,mode: .smooth,
            strength: 1,global: [],shortTracks: false,shortGraph: false,confidenceTargets: true)
        XCTAssertNotNil(clean[0]);XCTAssertNotNil(altered[0])
        let reliablyClipped = tracks(false).map { track in track.map { point in
            SurfaceTracking.Observation(frame: point.frame,x: point.x,y: point.y,channelLevels: point.channelLevels,
                confidence: point.confidence,sourcePeakLevel: point.frame == 0 ? 0 : point.sourcePeakLevel)
        } }
        XCTAssertTrue(SurfaceLighting.jointLighting(reliablyClipped,times: times,radius: 0.5,mode: .smooth,
            strength: 1,global: [],shortTracks: false,shortGraph: false,confidenceTargets: true).isEmpty)
        for i in times.indices where !unsupported.contains(i) {
            XCTAssertEqual(clean[0]?[i].channelEV[0] ?? 10,altered[0]?[i].channelEV[0] ?? -10,accuracy: 0.00001)
        }
    }

    func testUnsupportedMeasurementsCannotChangeSharedLightingIdentity() {
        let times = (0..<40).map { Double($0)/12 }
        let global = times.indices.map { 0.4*sin(Double($0)*0.7) }
        let unsupported = 15...23
        for followsGlobal in [true,false] {
            func history(_ altered: Bool) -> [SurfaceTracking.Observation] {
                times.indices.map { i in
                    let level = -3.0-(followsGlobal ? global[i] : 0)+(altered && unsupported.contains(i) ? 2 : 0)
                    return .init(frame: i,x: 12,y: 12,channelLevels: [level,level,level],confidence: unsupported.contains(i) ? 0 : 1)
                }
            }
            let clean = SurfaceTracking.lighting(history(false),times: times,radius: 0.5,mode: .smooth,
                strength: 1,global: global,confidenceTargets: true)
            let altered = SurfaceTracking.lighting(history(true),times: times,radius: 0.5,mode: .smooth,
                strength: 1,global: global,confidenceTargets: true)
            XCTAssertTrue(clean.allSatisfy { followsGlobal ? $0.usesSharedExposure : $0.protectsFromGlobal })
            for i in times.indices where !unsupported.contains(i) {
                XCTAssertEqual(clean[i].usesSharedExposure,altered[i].usesSharedExposure)
                XCTAssertEqual(clean[i].protectsFromGlobal,altered[i].protectsFromGlobal)
                XCTAssertEqual(clean[i].channelEV[0],altered[i].channelEV[0],accuracy: 0.00001)
            }
        }
    }

    func testConfidenceWeightedTargetsExcludeUnsupportedMeasurementsAndRetainControls() {
        for count in [13,120] {
            let times = (0..<count).map { Double($0)/12 }
            let corrupt = count == 13 ? 4...8 : 40...80
            func history(_ changed: Bool) -> [SurfaceTracking.Observation] {
                times.indices.map { i in
                    let level = -3.0+(changed && corrupt.contains(i) ? 2 : 0)
                    return .init(frame: i,x: 12,y: 12,channelLevels: [level,level,level],confidence: corrupt.contains(i) ? 0 : 1)
                }
            }
            for mode in [NormalisationMode.smooth,.steady] {
                let clean = SurfaceTracking.lighting(history(false),times: times,radius: 0.5,mode: mode,strength: 1,confidenceTargets: true)
                let changed = SurfaceTracking.lighting(history(true),times: times,radius: 0.5,mode: mode,strength: 1,confidenceTargets: true)
                for i in times.indices where !corrupt.contains(i) {
                    XCTAssertEqual(clean[i].channelEV[0],changed[i].channelEV[0],accuracy: 0.00001)
                }
                let half = SurfaceTracking.lighting(history(true),times: times,radius: 0.5,mode: mode,strength: 0.5,confidenceTargets: true)
                for i in times.indices { XCTAssertEqual(changed[i].channelEV[0],2*half[i].channelEV[0],accuracy: 0.00001) }
                let off = SurfaceTracking.lighting(history(true),times: times,radius: 0.5,mode: mode,strength: 0,confidenceTargets: true)
                XCTAssertTrue(off.allSatisfy { $0.channelEV.allSatisfy { $0 == 0 } })
            }
            let levels = times.map { -3+0.1*$0 }
            let old = ExposureMath.smoothTargets(times: times,levels: levels,radius: 0.5)
            XCTAssertEqual(ExposureMath.median(levels),ExposureMath.weightedMedian(levels,weights: Array(repeating: 0.3,count: count)))
            XCTAssertEqual(old,ExposureMath.smoothTargets(times: times,levels: levels,radius: 0.5,reliability: Array(repeating: 0.3,count: count)))
            XCTAssertEqual(levels,ExposureMath.smoothTargets(times: times,levels: levels,radius: 0.5,reliability: Array(repeating: 0,count: count)))
            var single = [Double](repeating: 0,count: count);single[count/2] = 1
            XCTAssertEqual(Array(repeating: levels[count/2],count: count),ExposureMath.smoothTargets(times: times,levels: levels,radius: 0.5,reliability: single))
        }
    }

    func testRegisteredCameraValidationSeparatesManufacturedGainFromSourceFlicker() {
        let w = 96,h = 56
        var seed: UInt64 = 17,rgb: [Float] = []
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
        let first = SpatialThumbnail(width: w,height: h,rgb: rgb)
        let second = SpatialThumbnail(width: w,height: h,rgb: shifted)
        let overcorrected = SpatialThumbnail(width: w,height: h,rgb: shifted.map { $0*Float(pow(2,0.2)) })
        let residual = SurfaceLighting.cameraValidationResidual(first,second,renderedA: first,renderedB: overcorrected)
        XCTAssertNotNil(residual)
        XCTAssertEqual(residual ?? 0,0.2,accuracy: 0.00001)
        let flicker = SpatialThumbnail(width: w,height: h,rgb: shifted.map { $0*Float(pow(2,0.4)) })
        XCTAssertNil(SurfaceLighting.cameraValidationResidual(first,flicker,renderedA: first,renderedB: second))
    }
    func testNeutralTextureSupportDistinguishesNeutralAndColouredPatchVariation() {
        func patch(_ blueOnly: Bool,_ constant: Bool = false) -> SpatialThumbnail {
            var rgb: [Float] = []
            for y in 0..<16 { for x in 0..<16 {
                let variation: Float = constant ? 0 : Float(x+y)*0.003
                rgb += blueOnly ? [0.3,0.12,0.06+variation] : [0.3+variation,0.12+variation,0.06+variation]
            } }
            return .init(width: 16,height: 16,rgb: rgb)
        }
        XCTAssertEqual(SurfaceTracking.neutralTextureSupport(patch(false),x: 8,y: 8) ?? 0,1,accuracy: 0.000001)
        XCTAssertLessThan(SurfaceTracking.neutralTextureSupport(patch(true),x: 8,y: 8) ?? 1,0.4)
        XCTAssertNil(SurfaceTracking.neutralTextureSupport(patch(false,true),x: 8,y: 8))
    }

    func testColourContrastPhotometryPreservesNeutralHighlightsWhileRemovingExposureFlicker() {
        let times = (0..<24).map { Double($0)/12 }
        let base = [0.33,0.105,0.055]
        var track: [SurfaceTracking.Observation] = [],expected: [[Double]] = []
        for frame in times.indices {
            let highlight = 0.015+0.01*sin(Double(frame)*0.91)
            let exposure = frame.isMultiple(of: 2) ? 0.35 : -0.35
            let clean = base.map { $0+highlight }
            expected.append(clean)
            track.append(.init(frame: frame,x: 12,y: 12,
                channelLevels: clean.map { log2($0)+exposure },confidence: 1,neutralTextureConfidence: 1))
        }
        let corrected = SurfaceTracking.lighting(track,times: times,radius: 0.5,mode: .steady,strength: 1,contrastPhotometry: true)
        XCTAssertEqual(corrected.count,track.count)
        XCTAssertTrue(corrected.allSatisfy(\.usesContrastPhotometry))
        for frame in times.indices { for channel in 0..<3 {
            let rendered = pow(2,track[frame].channelLevels[channel]+corrected[frame].channelEV[channel])
            XCTAssertEqual(rendered,expected[frame][channel],accuracy: 0.000001)
        } }
        let model = SurfaceTracking.contrastHistory(track)
        XCTAssertEqual(SurfaceTracking.contrastHistory(model).map(\.channelLevels),model.map(\.channelLevels))
        XCTAssertEqual(model.map(\.sourcePeakLevel),track.map { $0.channelLevels.max() })
    }

    func testColourContrastPhotometryRejectsChangingColourNeutralAndClippedEvidence() {
        let varyingColour = (0..<16).map { frame -> SurfaceTracking.Observation in
            let sign = frame.isMultiple(of: 2) ? 1.0 : -1.0
            return .init(frame: frame,x: 12,y: 12,
                channelLevels: [log2(0.33)+0.3*sign,log2(0.105)-0.3*sign,log2(0.055)],confidence: 1,neutralTextureConfidence: 1)
        }
        let neutral = (0..<16).map { frame in SurfaceTracking.Observation(frame: frame,x: 12,y: 12,
            channelLevels: Array(repeating: log2(0.2)+(frame.isMultiple(of: 2) ? 0.3 : -0.3),count: 3),confidence: 1,neutralTextureConfidence: 1) }
        let clipped = (0..<16).map { frame in SurfaceTracking.Observation(frame: frame,x: 12,y: 12,
            channelLevels: [log2(0.8),log2(0.4),log2(0.2)].map { $0+(frame.isMultiple(of: 2) ? 0.3 : -0.3) },confidence: 1,neutralTextureConfidence: 1) }
        for input in [varyingColour,neutral,clipped] {
            let result = SurfaceTracking.contrastHistory(input)
            XCTAssertEqual(result.map(\.channelLevels),input.map(\.channelLevels))
            XCTAssertFalse(result.contains(where: \.usesContrastPhotometry))
        }
    }

    func testDifferentMaterialsCanEstablishOneIlluminationHistory() {
        let times = (0..<52).map { Double($0)/12 }
        let bases = [[-2.0,-3.0,-4.0],[-4.0,-2.0,-3.0],[-3.0,-4.0,-2.0]]
        var tracks: [[SurfaceTracking.Observation]] = []
        for start in 0..<40 { for material in 0..<3 {
            var track: [SurfaceTracking.Observation] = []
            for frame in start..<start+5 {
                let light = 0.35*sin(Double(frame)*0.47)
                track.append(.init(frame: frame,x: 4+material*8,y: 12,
                    channelLevels: bases[material].map { $0+light },confidence: 1))
            }
            tracks.append(track)
        } }
        let joined = SurfaceLighting.jointLighting(tracks,times: times,radius: 0.5,mode: .steady,strength: 1,
            global: [],shortTracks: false,shortGraph: true,crossMaterials: true)
        XCTAssertGreaterThan(joined.count,90)
        var corrected: [Double] = []
        for (index,gains) in joined { for (point,gain) in zip(tracks[index],gains) {
            corrected.append(point.channelLevels[0]+gain.channelEV[0]-bases[index%3][0])
        } }
        if let low = corrected.min(),let high = corrected.max() { XCTAssertLessThan(high-low,0.01) }
        let separated = SurfaceLighting.jointLighting(tracks,times: times,radius: 0.5,mode: .steady,strength: 1,
            global: [],shortTracks: false,shortGraph: true,crossMaterials: false)
        XCTAssertTrue(separated.isEmpty)
    }

    func testOverlappingBriefTracksEstablishAFullLightingHistory() {
        let times = (0..<52).map { Double($0)/12 }
        var tracks: [[SurfaceTracking.Observation]] = []
        for start in 0..<40 { for material in 0..<3 {
            var track: [SurfaceTracking.Observation] = []
            for frame in start..<start+5 {
                let illumination = Double(material)*0.03+0.35*sin(Double(frame)*0.47)
                track.append(.init(frame: frame,x: 4+material*8,y: 12,
                    channelLevels: [-2+illumination,-3+illumination,-4+illumination],confidence: 1))
            }
            tracks.append(track)
        } }
        let joined = SurfaceLighting.jointLighting(tracks,times: times,radius: 0.5,mode: .steady,strength: 1,global: [],shortTracks: false,shortGraph: true)
        XCTAssertGreaterThan(joined.count,90)
        var corrected: [Double] = []
        for (index,gains) in joined { for (point,gain) in zip(tracks[index],gains) {
            corrected.append(point.channelLevels[0]+gain.channelEV[0]-Double(index%3)*0.03)
        } }
        if let low = corrected.min(),let high = corrected.max() { XCTAssertLessThan(high-low,0.01) }
        let brief = Array(tracks.prefix(9))
        XCTAssertTrue(SurfaceLighting.jointLighting(brief,times: times,radius: 0.5,mode: .steady,strength: 1,global: [],shortTracks: false,shortGraph: true).isEmpty)
    }

    func testShortTracksUseOnlyIndependentlyEstablishedLightingHistory() {
        let times = (0..<40).map { Double($0)/25 }
        func observations(_ frames: Range<Int>,x: Int,otherLight: Bool = false) -> [SurfaceTracking.Observation] {
            frames.map { frame in
                let light = 0.35*sin(Double(frame)*(otherLight ? 0.83 : 0.47))
                return .init(frame: frame,x: x,y: 12,channelLevels: [-2+light,-3+light,-4+light],confidence: 1)
            }
        }
        let longer = [observations(0..<40,x: 4),observations(0..<40,x: 12),observations(0..<40,x: 20)]
        let short = observations(8..<13,x: 28)
        let other = observations(8..<13,x: 36,otherLight: true)
        let tracks = longer+[short,other]
        let joined = SurfaceLighting.jointLighting(tracks,times: times,radius: 0.5,mode: .steady,strength: 1,global: [],shortTracks: true,shortGraph: false)
        XCTAssertNotNil(joined[3])
        XCTAssertNil(joined[4])
        for (point,correction) in zip(short,joined[3] ?? []) {
            let reference = joined[0]![point.frame]
            XCTAssertEqual(point.channelLevels[0]+correction.channelEV[0],longer[0][point.frame].channelLevels[0]+reference.channelEV[0],accuracy: 0.000001)
        }
        let disabled = SurfaceLighting.jointLighting(tracks,times: times,radius: 0.5,mode: .steady,strength: 1,global: [],shortTracks: false,shortGraph: false)
        XCTAssertNil(disabled[3])
        let duplicateDonors = [observations(0..<40,x: 4),observations(0..<40,x: 5),observations(0..<40,x: 6),short]
        let duplicates = SurfaceLighting.jointLighting(duplicateDonors,times: times,radius: 0.5,mode: .steady,strength: 1,global: [],shortTracks: true,shortGraph: false)
        XCTAssertNil(duplicates[3])
        let half = SurfaceLighting.jointLighting(tracks,times: times,radius: 0.5,mode: .steady,strength: 0.5,global: [],shortTracks: true,shortGraph: false)
        for (full,reduced) in zip(joined[3] ?? [],half[3] ?? []) {
            XCTAssertEqual(full.channelEV[0],reduced.channelEV[0]*2,accuracy: 0.000001)
        }
    }

    func testOverlappingFragmentsShareLightingTargetsWithoutJoiningIndependentLights() {
        let times = (0..<64).map { Double($0)/12 }
        func track(_ start: Int,_ index: Int,_ alternate: Bool = false) -> [SurfaceTracking.Observation] {
            (start..<start+24).map { frame in
                let light = alternate ? 0.4*sin(Double(frame)*0.8) : (frame%3 == 0 ? 0.4 : -0.4)
                return .init(frame: frame,x: 8+index*4,y: 12,channelLevels: [-2+Double(index)*0.1+light,-3+Double(index)*0.1+light,-4+Double(index)*0.1+light],confidence: 1)
            }
        }
        let tracks = [track(0,0),track(10,1),track(20,2),track(30,3),track(10,4,true)]
        let joint = SurfaceLighting.jointLighting(tracks,times: times,radius: 0.5,mode: .steady,strength: 1,global: Array(repeating: 0,count: times.count))
        XCTAssertEqual(Set(joint.keys),Set([0,1,2,3]))
        for index in 0..<4 {
            let corrected = zip(tracks[index],joint[index]!).map { $0.channelLevels[0]+$1.channelEV[0] }
            XCTAssertLessThan(corrected.max()!-corrected.min()!,0.001)
        }
        let half = SurfaceLighting.jointLighting(tracks,times: times,radius: 0.5,mode: .steady,strength: 0.5,global: Array(repeating: 0,count: times.count))
        for index in 0..<4 { for (full,reduced) in zip(joint[index]!,half[index]!) {
            XCTAssertEqual(full.channelEV[0],reduced.channelEV[0]*2,accuracy: 0.000001)
        } }
    }

    func testJointHistoryRejectsNearClippedChannels() {
        let times = (0..<24).map { Double($0)/12 }
        let tracks = (0..<4).map { k in times.indices.map { frame in
            let change = frame.isMultiple(of: 2) ? 0.15 : -0.15
            return SurfaceTracking.Observation(frame: frame,x: 4+k*4,y: 8,
                channelLevels: [-0.1,-2+change,-3+change],confidence: 1)
        } }
        XCTAssertTrue(SurfaceLighting.jointLighting(tracks,times: times,radius: 0.5,
            mode: .smooth,strength: 1,global: []).isEmpty)
    }

    func testJointFragmentsDoNotReplaceValidatedSharedExposure() {
        let times = (0..<40).map { Double($0)/12 }
        let global = times.indices.map { $0.isMultiple(of: 2) ? 0.3 : -0.3 }
        let tracks = (0..<4).map { k in
            (k*3..<(28+k*3)).map { frame in
                SurfaceTracking.Observation(frame: frame,x: 4+k*4,y: 8,
                    channelLevels: Array(repeating: -2+Double(k)*0.05-global[frame],count: 3),confidence: 1)
            }
        }
        let joint = SurfaceLighting.jointLighting(tracks,times: times,radius: 0.5,mode: .smooth,strength: 1,global: global)
        XCTAssertEqual(joint.count,4)
        for k in tracks.indices {
            let independent = SurfaceTracking.lighting(tracks[k],times: times,radius: 0.5,mode: .smooth,strength: 1,global: global)
            XCTAssertTrue(independent.allSatisfy(\.usesSharedExposure))
            XCTAssertEqual(joint[k]!.map(\.channelEV),independent.map(\.channelEV))
        }
    }

    func testSharedExposureRequiresIndependentEvidenceAndProtectsStableSurfaces() {
        func point(_ x: Int,_ gain: Double) -> SurfaceTracking.LightingEstimate {
            .init(frame: 0,x: x*4,y: 8,channelEV: Array(repeating: gain,count: 3),confidence: 1,protectsFromGlobal: gain == 0)
        }
        let background = (0..<20).map { point($0,-0.4) }
        let foreground = (20..<26).map { point($0,0) }
        XCTAssertEqual(SurfaceLighting.sharedExposure(background+foreground,global: -0.4,strength: 1),0,accuracy: 0.000001)
        XCTAssertEqual(SurfaceLighting.sharedExposure(background,global: -0.4,strength: 1),-0.4,accuracy: 0.000001)
        XCTAssertEqual(SurfaceLighting.sharedExposure(background+Array(repeating: point(24,0),count: 50),global: -0.4,strength: 1),-0.4,accuracy: 0.000001)
        let half = (background+foreground).map { SurfaceTracking.LightingEstimate(frame: $0.frame,x: $0.x,y: $0.y,
            channelEV: $0.channelEV.map { $0*0.5 },confidence: $0.confidence,protectsFromGlobal: $0.protectsFromGlobal) }
        XCTAssertEqual(SurfaceLighting.sharedExposure(half,global: -0.2,strength: 0.5),0,accuracy: 0.000001)
    }

    func testSeparatedGlobalCurveKeepsSpatialZeroAndPartialEndpointsConsistent() {
        let map = SurfaceLighting.Map(width: 2,height: 2,channelEV: Array(repeating: 0.2,count: 12),guide: Array(repeating: 0.2,count: 12))
        var field = SpatialField();field.surface = map;field.sharedExposureEV = -0.1
        let curve = SurfaceLighting.separatedCurve(times: [0],global: [-0.4],fields: [field],spatialStrength: 0.5)
        XCTAssertEqual(curve.stops,[-0.1])
        XCTAssertEqual(Double(curve.spatial[0].surface!.channelEV[0])+curve.stops[0],-0.2,accuracy: 0.000001)
        let zero = SurfaceLighting.separatedCurve(times: [0],global: [-0.4],fields: [field],spatialStrength: 0)
        XCTAssertEqual(zero.stops,[-0.1])
        XCTAssertEqual(zero.spatial[0].surface!.channelEV,Array(repeating: 0,count: 12))
    }

    func testRenderedRefinementRequiresImprovementOnWithheldAnchors() {
        let w = 48,h = 32
        let guide = Array(repeating: Float(0.2),count: w*h*3)
        let map = SurfaceLighting.Map(width: w,height: h,channelEV: Array(repeating: 0.2,count: w*h*3),guide: guide)
        func points(conflict: Bool) -> [SurfaceTracking.LightingEstimate] {
            stride(from: 2,to: h-2,by: 4).flatMap { y in stride(from: 2,to: w-2,by: 4).map { x in
                let held = (x/4)%5 == 0 && (y/4)%3 == 0
                return SurfaceTracking.LightingEstimate(frame: 0,x: x,y: y,
                    channelEV: Array(repeating: conflict && held ? 0.2 : 0,count: 3),confidence: 1)
            } }
        }
        let improved = SurfaceLighting.refined(map,points: points(conflict: false),global: 0,shared: 0,strength: 1,spatialStrength: 1)
        XCTAssertLessThan(abs(improved.channelEV[(16*w+24)*3]),0.06)
        let rejected = SurfaceLighting.refined(map,points: points(conflict: true),global: 0,shared: 0,strength: 1,spatialStrength: 1)
        XCTAssertEqual(rejected.channelEV,map.channelEV)
        XCTAssertEqual(SurfaceLighting.refined(map,points: points(conflict: false),global: 0,shared: 0,strength: 1,spatialStrength: 0).channelEV,map.channelEV)
    }

    func testRefinementHonoursColourAndRejectsDarkWindowEvidence() {
        let w = 48,h = 32
        let guide = (0..<w*h).flatMap { _ in [Float(0.12),Float(0.25),Float(0.35)] }
        let gains = (0..<w*h).flatMap { _ in [Float(0.3),Float(0.1),Float(-0.1)] }
        let points = stride(from: 2,to: h-2,by: 4).flatMap { y in
            stride(from: 2,to: w-2,by: 4).map { x in
                SurfaceTracking.LightingEstimate(frame: 0,x: x,y: y,channelEV: [0,0,0],confidence: 1)
            }
        }
        let map = SurfaceLighting.Map(width: w,height: h,channelEV: gains,guide: guide)
        for amount in [0.0,0.5,1.0] {
            let refined = SurfaceLighting.refined(map,points: points,global: 0,shared: 0,
                strength: 1,spatialStrength: 1,colourStrength: amount)
            let actual = SurfaceLighting.colourAdjustedGains(refined.channelEV,guide: guide,amount: amount)
            let original = SurfaceLighting.colourAdjustedGains(gains,guide: guide,amount: amount)
            let weights = [0.2126,0.7152,0.0722]
            func luminanceError(_ values: [Float]) -> Double {
                (0..<w*h).reduce(0.0) { sum,p in
                    let source = (0..<3).reduce(0.0) { $0+weights[$1]*Double(guide[p*3+$1]) }
                    let output = (0..<3).reduce(0.0) { $0+weights[$1]*Double(guide[p*3+$1])*pow(2,Double(values[p*3+$1])) }
                    return sum+pow(log2(output/source),2)
                }
            }
            XCTAssertLessThanOrEqual(luminanceError(actual),luminanceError(original)+0.000001)
            if amount == 0 {
                for p in 0..<w*h {
                    XCTAssertEqual(actual[p*3],actual[p*3+1],accuracy: 0.000001)
                    XCTAssertEqual(actual[p*3],actual[p*3+2],accuracy: 0.000001)
                }
            }
        }
        var darkGuide = guide
        for y in 0..<h { for x in 0..<w where x.isMultiple(of: 4) { darkGuide[(y*w+x)*3] = 0.0001 } }
        let dark = SurfaceLighting.Map(width: w,height: h,channelEV: gains,guide: darkGuide)
        XCTAssertEqual(SurfaceLighting.refined(dark,points: points,global: 0,shared: 0,
            strength: 1,spatialStrength: 1,colourStrength: 0.5).channelEV,gains)
    }

    func testIsolatedFlashUsesSharedTargetButAnUnchangedSurfaceDoesNot() {
        let times = (0..<24).map { Double($0)/12 }
        let global = times.indices.map { $0 == 5 ? -0.8 : 0.0 }
        let observations = (2..<10).map { i in SurfaceTracking.Observation(frame: i,x: 8,y: 10,
            channelLevels: Array(repeating: -2-global[i],count: 3),confidence: 1) }
        let corrected = SurfaceTracking.lighting(observations,times: times,radius: 0.5,mode: .smooth,strength: 1,global: global)
        for (source,result) in zip(observations,corrected) {
            XCTAssertEqual(source.channelLevels[0]+result.channelEV[0],-2,accuracy: 0.000001)
        }
        let stable = observations.map { SurfaceTracking.Observation(frame: $0.frame,x: $0.x,y: $0.y,
            channelLevels: [-2,-2,-2],confidence: 1) }
        XCTAssertLessThan(SurfaceTracking.lighting(stable,times: times,radius: 0.5,mode: .smooth,strength: 1,global: global).flatMap(\.channelEV).map(abs).max()!,0.000001)
    }
    private func image(dx: Int = 0, dy: Int = 0, ev: [Double] = [0,0,0], flat: Bool = false, gradientX: Double = 0, gradientY: Double = 0) -> SpatialThumbnail {
        let w = 32, h = 24
        var rgb = [Float]()
        for y in 0..<h { for x in 0..<w {
            let xx = x-dx, yy = y-dy
            for c in 0..<3 {
                let seed = ((xx*37 + yy*59 + xx*yy*13 + c*17) % 101 + 101) % 101
                let value = flat ? 0.2 : 0.1 + Double(seed)/500
                rgb.append(Float(value * pow(2,ev[c]+gradientX*Double(x)+gradientY*Double(y))))
            }
        } }
        return SpatialThumbnail(width: w, height: h, rgb: rgb)
    }

    func testCameraMatchRequiresCoherentPhotometricEvidence() {
        XCTAssertEqual(SurfaceLighting.motionPhotometricConfidence(delta: [0.4,-0.2,0.1],common: [0.4,-0.2,0.1]),1,accuracy: 0.000001)
        XCTAssertLessThan(SurfaceLighting.motionPhotometricConfidence(delta: [0.8,0,0],common: [0,0,0]),0.01)
        XCTAssertGreaterThan(SurfaceLighting.motionPhotometricConfidence(delta: [0.02,0.01,0],common: [0,0,0]),0.95)
    }

    private func cameraImage(dx: Double = 0,dy: Double = 0,angle: Double = 0,scale: Double = 1,ev: Double = 0) -> SpatialThumbnail {
        let w = 128,h = 80
        var rgb = [Float]()
        for y in 0..<h { for x in 0..<w {
            let xx = Double(x)-64-dx,yy = Double(y)-40-dy
            let sx = (cos(angle)*xx+sin(angle)*yy)/scale+64
            let sy = (-sin(angle)*xx+cos(angle)*yy)/scale+40
            for c in 0..<3 {
                let light = 0.18+0.06*sin(sx*0.43+Double(c))+0.04*cos(sy*0.51)+0.03*sin(sx*0.17+sy*0.31)
                rgb.append(Float(light*pow(2,ev)))
            }
        } }
        return SpatialThumbnail(width: w,height: h,rgb: rgb)
    }

    func testSubpixelCorrespondenceKeepsExposureSeparateFromFractionalMotion() throws {
        let source = SurfaceTracking.Prepared(cameraImage())
        let target = SurfaceTracking.Prepared(cameraImage(dx: 0.5,dy: -0.25,ev: 0.4))
        let result = try XCTUnwrap(SurfaceTracking.match(source,target,x: 40,y: 28,radius: 3,subpixel: true))
        XCTAssertEqual(Double(result.x)+result.offsetX,40.5,accuracy: 0.26)
        XCTAssertEqual(Double(result.y)+result.offsetY,27.75,accuracy: 0.26)
        for gain in result.channelEV { XCTAssertEqual(gain,0.4,accuracy: 0.025) }
        let recovered = try XCTUnwrap(SurfaceTracking.match(target,source,x: result.x,y: result.y,radius: 3,
            offsetX: result.offsetX,offsetY: result.offsetY,subpixel: true))
        XCTAssertEqual(Double(recovered.x)+recovered.offsetX,40,accuracy: 0.26)
        XCTAssertEqual(Double(recovered.y)+recovered.offsetY,28,accuracy: 0.26)
    }

    func testCoarseCameraModelTracksRotationZoomAndLargerTranslation() throws {
        let source = cameraImage()
        for (dx,dy,angle,scale) in [(10.0,-4.0,0.0,1.0),(3.0,-2.0,0.07,1.06)] {
            let reference = cameraImage(dx: dx,dy: dy,angle: angle,scale: scale,ev: 0.4)
            let model = try XCTUnwrap(SurfaceMotion.estimate(SurfaceMotion.coarse(source),SurfaceMotion.coarse(reference)))
            let p = model.point(40,28)
            let expected = (64+dx+scale*(cos(angle)*(-24)-sin(angle)*(-12)),40+dy+scale*(sin(angle)*(-24)+cos(angle)*(-12)))
            XCTAssertEqual(p.0,expected.0,accuracy: 1.5)
            XCTAssertEqual(p.1,expected.1,accuracy: 1.5)
            let reverse = try XCTUnwrap(model.inverse(p.0,p.1))
            XCTAssertEqual(reverse.0,40,accuracy: 0.00001)
            XCTAssertEqual(reverse.1,28,accuracy: 0.00001)
            let match = try XCTUnwrap(SurfaceTracking.match(.init(source),.init(reference),x: 40,y: 28,radius: 3,motion: model))
            XCTAssertEqual(Double(match.x),expected.0,accuracy: 1.5)
            XCTAssertEqual(Double(match.y),expected.1,accuracy: 1.5)
        }
    }

    func testCameraPredictionDoesNotReplaceAnExactRepeatedTextureMatch() throws {
        let w = 64,h = 24
        var source = [Float](),reference = [Float]()
        for y in 0..<h { for x in 0..<w {
            let texture = 0.2+0.07*sin(Double(x%24)*0.7)+0.05*cos(Double(y)*0.9)
            for _ in 0..<3 {
                source.append(Float(texture))
                reference.append(Float(texture*(x >= 32 ? 1.5 : 1)))
            }
        } }
        let a = SurfaceTracking.Prepared(.init(width: w,height: h,rgb: source))
        let b = SurfaceTracking.Prepared(.init(width: w,height: h,rgb: reference))
        let prediction = SurfaceMotion.Model(x: [1,0,24],y: [0,1,0])
        let match = try XCTUnwrap(SurfaceTracking.match(a,b,x: 16,y: 12,radius: 0,motion: prediction))
        XCTAssertEqual(match.x,16)
        XCTAssertEqual(match.y,12)
        XCTAssertLessThan(match.channelEV.map(abs).max()!,0.000001)
    }

    func testExposureChangeDoesNotBecomeCameraMotion() {
        XCTAssertNil(SurfaceMotion.estimate(SurfaceMotion.coarse(cameraImage()),SurfaceMotion.coarse(cameraImage(ev: 0.6))))
    }

    func testInterruptedTrackUsesSharedExposureWithoutBorrowingBackgroundFlashes() {
        let times = (0..<24).map { Double($0)/12 }
        let flash = times.indices.map { $0%3 == 0 ? -0.4 : 0.4 }
        let global = flash.map { -$0 }
        let observations = (2..<10).map { frame in SurfaceTracking.Observation(frame: frame,x: 8,y: 10,
            channelLevels: [-2+flash[frame],-3+flash[frame],-4+flash[frame]],confidence: 1) }
        let estimates = SurfaceTracking.lighting(observations,times: times,radius: 0.5,mode: .steady,strength: 1,global: global)
        for (point,estimate) in zip(observations,estimates) {
            for c in 0..<3 { XCTAssertEqual(point.channelLevels[c]+estimate.channelEV[c],Double(-2-c),accuracy: 0.000001) }
        }
        let foreground = observations.map { SurfaceTracking.Observation(frame: $0.frame,x: $0.x,y: $0.y,channelLevels: [-2,-3,-4],confidence: 1) }
        let stable = SurfaceTracking.lighting(foreground,times: times,radius: 0.5,mode: .steady,strength: 1,global: global)
        XCTAssertLessThan(stable.flatMap(\.channelEV).map(abs).max()!,0.000001)
        let half = SurfaceTracking.lighting(observations,times: times,radius: 0.5,mode: .steady,strength: 0.5,global: global.map { $0*0.5 })
        for (full,reduced) in zip(estimates,half) {
            for c in 0..<3 { XCTAssertEqual(full.channelEV[c],reduced.channelEV[c]*2,accuracy: 0.000001) }
        }
    }

    func testSingleAppearanceJumpDoesNotEstablishSharedFlicker() {
        let times = (0..<24).map { Double($0)/12 }
        let global = times.indices.map { $0 >= 2 && $0 < 8 ? -0.4 : 0 }
        let track = (0..<8).map { frame in SurfaceTracking.Observation(frame: frame,x: 8,y: 10,
            channelLevels: Array(repeating: -2-global[frame],count: 3),confidence: 1) }
        let independent = SurfaceTracking.lighting(track,times: times,radius: 0.5,mode: .steady,strength: 1)
        let checked = SurfaceTracking.lighting(track,times: times,radius: 0.5,mode: .steady,strength: 1,global: global)
        XCTAssertEqual(checked.map(\.channelEV),independent.map(\.channelEV))
    }

    func testDistantMaterialFallbackRetainsTrackingConfidence() throws {
        let weak = try XCTUnwrap(SurfaceLighting.materialConsensus(Array(repeating: (ev: 0.8,confidence: 0.05),count: 4)))
        XCTAssertEqual(weak.reliability,0.05,accuracy: 0.000001)
        let strong = try XCTUnwrap(SurfaceLighting.materialConsensus(Array(repeating: (ev: 0.8,confidence: 1.0),count: 4)))
        XCTAssertEqual(strong.reliability,1,accuracy: 0.000001)
        let mixed = try XCTUnwrap(SurfaceLighting.materialConsensus([(ev: 0.2,confidence: 1),(ev: 0.2,confidence: 1),(ev: 1,confidence: 0.01),(ev: 1,confidence: 0.01)]))
        XCTAssertEqual(mixed.ev,0.2,accuracy: 0.000001)
        XCTAssertLessThan(mixed.reliability,0.51)
        XCTAssertNil(SurfaceLighting.materialConsensus([(ev: 0.8,confidence: 0),(ev: 0.8,confidence: 0)]))
        let full = try XCTUnwrap(SurfaceLighting.materialConsensus([(ev: 0.1,confidence: 1),(ev: 0.3,confidence: 1)]))
        let half = try XCTUnwrap(SurfaceLighting.materialConsensus([(ev: 0.05,confidence: 1),(ev: 0.15,confidence: 1)],strength: 0.5))
        XCTAssertEqual(full.reliability,half.reliability,accuracy: 0.000001)
        XCTAssertEqual(full.ev,half.ev*2,accuracy: 0.000001)
    }

    func testColourAmountPreservesLuminanceAndHasCorrectEndpoints() {
        let guide: [Float] = [0.04,0.2,0.5]
        let gains: [Float] = [0.8,-0.3,0.2]
        let weights = [0.2126,0.7152,0.0722]
        func light(_ stops: [Float]) -> Double {
            (0..<3).reduce(0) { $0+weights[$1]*Double(guide[$1])*pow(2,Double(stops[$1])) }
        }
        XCTAssertEqual(SurfaceLighting.colourAdjustedGains(gains,guide: guide,amount: 1),gains)
        let neutral = SurfaceLighting.colourAdjustedGains(gains,guide: guide,amount: 0)
        XCTAssertEqual(neutral[0],neutral[1],accuracy: 0.000001)
        XCTAssertEqual(neutral[1],neutral[2],accuracy: 0.000001)
        for amount in [0.0,0.25,0.5,0.75,1] {
            let output = SurfaceLighting.colourAdjustedGains(gains,guide: guide,amount: amount)
            XCTAssertEqual(light(output),light(gains),accuracy: 0.0000001)
        }
    }

    func testHeldPatchValidationDoesNotBorrowBrightnessFromDifferentMaterial() {
        let w = 48, h = 28
        let rgb: [Float] = (0..<(w*h)).flatMap { p in p%w < w/2 ? [0.25,0.08,0.04] : [0.04,0.1,0.4] }
        let map = SurfaceLighting.Map(width: w,height: h,channelEV: Array(repeating: 0,count: w*h*3),guide: rgb)
        let patches = (0..<336).filter { $0%24 < 12 }.map { ($0,0.12) }
        let corrected = SurfaceLighting.validatedGains(map,residuals: patches,amount: 1)
        let half = SurfaceLighting.validatedGains(map,residuals: patches,amount: 0.5)
        let left = (14*w+8)*3, right = (14*w+32)*3
        XCTAssertEqual(corrected.channelEV[left],0.12,accuracy: 0.00001)
        XCTAssertEqual(half.channelEV[left],0.06,accuracy: 0.00001)
        XCTAssertEqual(corrected.channelEV[right],0,accuracy: 0.00001)
        XCTAssertEqual(corrected.channelEV[left],corrected.channelEV[left+2],accuracy: 0.00001)
        XCTAssertEqual(SurfaceLighting.validatedGains(map,residuals: patches,amount: 0).channelEV,map.channelEV)
        XCTAssertEqual(SurfaceLighting.validatedGains(map,residuals: Array(patches.prefix(4)),amount: 1).channelEV,map.channelEV)
    }

    func testMovingSurfaceUnderIndependentColourExposureChanges() {
        let source = image()
        let reference = image(dx: 4, dy: -3, ev: [0.5,-0.3,0.2])
        let match = SurfaceTracking.match(source, reference, x: 15, y: 12)
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.x, 19)
        XCTAssertEqual(match?.y, 9)
        for c in 0..<3 { XCTAssertEqual(match?.channelEV[c] ?? 99, [0.5,-0.3,0.2][c], accuracy: 0.00001) }
    }

    func testContrastInvariantCorrespondencePreservesRawPhotometry() throws {
        let source = image()
        let moved = image(dx: 4,dy: -3)
        let changed = SpatialThumbnail(width: moved.width,height: moved.height,
            rgb: moved.rgb.map { Float(pow(Double($0),1.8)*2) })
        let match = try XCTUnwrap(SurfaceTracking.match(SurfaceTracking.Prepared(source),SurfaceTracking.Prepared(changed),
            x: 15,y: 12,contrastInvariant: true))
        XCTAssertEqual(match.x,19)
        XCTAssertEqual(match.y,9)
        for c in 0..<3 {
            var mean = 0.0
            for dy in -2...2 { for dx in -2...2 {
                mean += log2(Double(source.rgb[((12+dy)*source.width+15+dx)*3+c]))/25
            } }
            XCTAssertEqual(match.channelEV[c],0.8*mean+1,accuracy: 0.000001)
        }
        XCTAssertGreaterThan(match.confidence,0.9)
        XCTAssertLessThan(match.photometricConfidence,0.3)
        let ordinary = SurfaceTracking.match(SurfaceTracking.Prepared(source),SurfaceTracking.Prepared(changed),
            x: 15,y: 12,contrastInvariant: false)
        XCTAssertLessThan(ordinary?.confidence ?? 0,match.confidence)
    }

    func testLightingGradientDoesNotMoveTheTrackedTexture() {
        let match = SurfaceTracking.match(image(),image(dx: 4,dy: -3,ev: [0.5,-0.3,0.2],gradientX: 0.04,gradientY: -0.03),x: 15,y: 12)
        XCTAssertEqual(match?.x,19)
        XCTAssertEqual(match?.y,9)
        for c in 0..<3 { XCTAssertEqual(match?.channelEV[c] ?? 99,[0.5,-0.3,0.2][c]+0.04*19-0.03*9,accuracy: 0.00001) }
    }

    func testRowModelRequiresSpatialConsensusAndScalesWithStrength() throws {
        func points(_ gain: (Int,Int) -> Double) -> [SurfaceTracking.LightingEstimate] {
            (0..<13).flatMap { row in (0..<24).map { col in
                SurfaceTracking.LightingEstimate(frame: 0,x: 2+col*4,y: 2+row*4,
                    channelEV: Array(repeating: gain(row,col),count: 3),confidence: 1)
            } }
        }
        let signal = points { row, _ in 0.3*sin(Double(2+row*4)*Double.pi/14) }
        let localized = signal.filter { $0.x < 40 }
        XCTAssertNil(SurfaceLighting.rowIllumination(localized,width: 96,height: 56))
        let duplicates = localized.flatMap { Array(repeating: $0,count: 10) }
        XCTAssertNil(SurfaceLighting.rowIllumination(duplicates,width: 96,height: 56))
        let model = try XCTUnwrap(SurfaceLighting.rowIllumination(signal,width: 96,height: 56))
        XCTAssertNotNil(SurfaceLighting.rowIllumination(signal.filter { $0.y != 26 },width: 96,height: 56))
        XCTAssertNil(SurfaceLighting.rowIllumination(signal.filter { $0.y != 26 && $0.y != 30 },width: 96,height: 56))
        XCTAssertNil(SurfaceLighting.rowIllumination(signal.filter { $0.y != 2 },width: 96,height: 56))
        let half = signal.map { SurfaceTracking.LightingEstimate(frame: $0.frame,x: $0.x,y: $0.y,
            channelEV: $0.channelEV.map { $0*0.5 },confidence: $0.confidence) }
        let halfModel = try XCTUnwrap(SurfaceLighting.rowIllumination(half,width: 96,height: 56,strength: 0.5))
        for y in 0..<56 { XCTAssertEqual(halfModel[y][0],model[y][0]*0.5,accuracy: 0.000001) }
        XCTAssertNil(SurfaceLighting.rowIllumination(points { _,_ in 0.4 },width: 96,height: 56))
        XCTAssertNil(SurfaceLighting.rowIllumination(points { _,col in 0.8*exp(-pow(Double(col-8)/8,2)) },width: 96,height: 56))
    }

    func testGainRegularizerReducesIslandsAndRetainsMaterialBoundaries() {
        let w = 48, h = 32
        let guide = (0..<(w*h)).flatMap { p -> [Float] in p%w < w/2 ? [0.12,0.2,0.1] : [0.35,0.1,0.08] }
        let gains = (0..<(w*h)).flatMap { p -> [Float] in
            let x = p%w,y = p/w
            let gain: Float = x >= w/2 ? -0.4 : (abs(x-12) <= 2 && abs(y-16) <= 2 ? 0.8 : 0.2)
            return Array(repeating: gain,count: 3)
        }
        let output = SurfaceLighting.regularizedGains(gains,guide: guide,width: w,height: h,preserveLightingBoundaries: false)
        XCTAssertLessThan(output[(16*w+12)*3],0.3)
        XCTAssertEqual(output[(16*w+30)*3],-0.4,accuracy: 0.001)
        let constant = Array(repeating: Float(0.3),count: w*h*3)
        let unchanged = SurfaceLighting.regularizedGains(constant,guide: guide,width: w,height: h)
        XCTAssertLessThan(unchanged.map { abs($0-0.3) }.max()!,0.000001)
    }

    func testGainRegularizerPreservesIndependentLightingWithIdenticalReflectance() {
        let w = 48,h = 32
        let guide = Array(repeating: Float(0.2),count: w*h*3)
        let gains = (0..<(w*h)).flatMap { p in
            Array(repeating: Float(p%w < w/2 ? 0.3 : -0.4),count: 3)
        }
        let output = SurfaceLighting.regularizedGains(gains,guide: guide,width: w,height: h,preserveLightingBoundaries: true)
        XCTAssertGreaterThan(output[(16*w+23)*3],0.29)
        XCTAssertLessThan(output[(16*w+24)*3],-0.39)
        let half = SurfaceLighting.regularizedGains(gains.map { $0*0.5 },guide: guide,width: w,height: h,strength: 0.5,preserveLightingBoundaries: true)
        for k in output.indices { XCTAssertEqual(half[k],output[k]*0.5,accuracy: 0.000001) }
    }

    func testNeutralMovingSubjectIsProtectedFromBackgroundOnlyFlashes() {
        let width = 48,height = 32
        let samples = (0..<24).map { frame -> ExposureSample in
            let flash = frame.isMultiple(of: 2) ? 0.35 : -0.35
            var rgb = [Float]()
            for y in 0..<height { for x in 0..<width {
                let inside = x >= 4+frame && x < 14+frame && y >= 8 && y < 24
                let background = (0.12+Double((x*37+y*59+x*y*13)%101)/5000)*pow(2,flash)
                let light = inside ? Float(0.4) : Float(background)
                rgb.append(contentsOf: [light,light,light])
            } }
            return ExposureSample(time: Double(frame)/12,level: -3+flash,segment: 0,
                thumbnail: SpatialThumbnail(width: width,height: height,rgb: rgb))
        }
        let global = samples.indices.map { $0.isMultiple(of: 2) ? -0.35 : 0.35 }
        let fields = SurfaceLighting.estimate(samples: samples,global: global,radius: 0.5,strength: 1,mode: .steady)
        let errors = fields.indices.dropFirst(3).dropLast(3).map { frame -> Double in
            let gain = fields[frame].surface!.channelEV[(16*width+9+frame)*3]
            return abs(Double(gain)+global[frame])
        }
        XCTAssertLessThan(errors.reduce(0,+)/Double(errors.count),0.08)
        XCTAssertLessThan(errors.max()!,0.15)
    }

    func testMovingNeutralSubjectWithoutFlickerDoesNotCreateLightingCorrection() {
        let width = 48, height = 32
        let samples = (0..<24).map { frame -> ExposureSample in
            var rgb = [Float]()
            for y in 0..<height { for x in 0..<width {
                let inside = x >= 4+frame && x < 14+frame && y >= 10 && y < 22
                let light = inside ? Float(0.35) : Float(0.12+Double((x*37+y*59+x*y*13)%101)/5000)
                rgb.append(contentsOf: [light,light,light])
            } }
            return ExposureSample(time: Double(frame)/12,level: -3,segment: 0,
                thumbnail: SpatialThumbnail(width: width,height: height,rgb: rgb))
        }
        let fields = SurfaceLighting.estimate(samples: samples,global: Array(repeating: 0,count: samples.count),
            radius: 0.5,strength: 1,mode: .smooth)
        XCTAssertEqual(fields.count,samples.count)
        // There is no lighting change anywhere: translating reflectance must
        // not manufacture a local exposure field, even for achromatic material.
        let peak = fields.compactMap(\.surface).flatMap(\.channelEV).map { abs(Double($0)) }.max() ?? 99
        XCTAssertLessThan(peak,0.03)
    }

    func testStationaryFallbackNeedsIdentityBeyondNeutralColour() {
        let flat = image(flat: true)
        let brighterNeutral = image(ev: [1,1,1],flat: true)
        XCTAssertEqual(SurfaceTracking.stationaryConfidence(flat,brighterNeutral,x: 15,y: 12),0)
        XCTAssertGreaterThan(SurfaceTracking.stationaryConfidence(image(),image(ev: [0.5,0.5,0.5]),x: 15,y: 12),0.6)
        XCTAssertEqual(SurfaceTracking.stationaryConfidence(image(),image(dx: 4),x: 15,y: 12),0)
    }

    func testFlatAndOccludedPatchesDoNotSupplyMotionEvidence() {
        XCTAssertNil(SurfaceTracking.match(image(flat: true), image(flat: true), x: 15, y: 12))
        XCTAssertNil(SurfaceTracking.match(image(), image(flat: true), x: 15, y: 12))
        XCTAssertNil(SurfaceTracking.match(image(), image(), x: 0, y: 0))
    }

    func testTrajectoryFollowsTheSurfaceAndStopsAtSceneCut() {
        let frames = (0..<5).map { SurfaceTracking.Prepared(image(dx: $0, ev: [Double($0)*0.1,0,0])) }
        let observations = SurfaceTracking.trajectory(frames, segments: [0,0,0,1,1], start: 0, x: 12, y: 10)
        XCTAssertEqual(observations.map(\.frame), [0,1,2])
        XCTAssertEqual(observations.map(\.x), [12,13,14])
        XCTAssertEqual(observations[2].channelLevels[0]-observations[0].channelLevels[0], 0.2, accuracy: 0.00001)
        let occluded = [SurfaceTracking.Prepared(image()), SurfaceTracking.Prepared(image(flat: true))]
        XCTAssertEqual(SurfaceTracking.trajectory(occluded, segments: [0,0], start: 0, x: 12, y: 10).count, 1)
    }

    func testLightingSeparatesChannelsAndRetainsAnUnchangedMovingSurface() {
        let times = (0..<48).map { Double($0)/12 }
        let stable = times.indices.map { SurfaceTracking.Observation(frame: $0, x: 8+$0, y: 10,
            channelLevels: [-2,-3,-4], confidence: 1) }
        let unchanged = SurfaceTracking.lighting(stable, times: times, radius: 0.5, mode: .smooth, strength: 1)
        XCTAssertEqual(unchanged.count, 48)
        XCTAssertLessThan(unchanged.flatMap(\.channelEV).map(abs).max()!, 0.000001)
        let flicker = times.indices.map { i in
            SurfaceTracking.Observation(frame: i, x: 8+i, y: 10,
                channelLevels: [-2 + (i.isMultiple(of: 2) ? -0.4 : 0.4),-3,-4], confidence: 1)
        }
        let correction = SurfaceTracking.lighting(flicker, times: times, radius: 0.5, mode: .steady, strength: 1)
        for (index, estimate) in correction.enumerated() {
            XCTAssertEqual(flicker[index].channelLevels[0]+estimate.channelEV[0], -2, accuracy: 0.000001)
            XCTAssertEqual(estimate.channelEV[1], 0, accuracy: 0.000001)
            XCTAssertEqual(estimate.channelEV[2], 0, accuracy: 0.000001)
        }
        XCTAssertTrue(SurfaceTracking.lighting(Array(stable.prefix(3)), times: times, radius: 0.5, mode: .smooth, strength: 1).isEmpty)
    }
    func testCameraGuidedShapeRejectsWrongPositionAndFlatEvidence() throws {
        let w = 40,h = 32
        var seed: UInt64 = 721,rgb = [Float]()
        for _ in 0..<w*h {
            seed = seed &* 6364136223846793005 &+ 1
            let y = Float((seed >> 32)%1000)/10000+0.08
            rgb += [y,y*0.8,y*0.6]
        }
        var shifted = rgb
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            shifted[(y*w+x)*3+c] = rgb[(y*w+max(0,x-2))*3+c]*Float(pow(2,0.4))
        } } }
        let a = SpatialThumbnail(width:w,height:h,rgb:rgb),b = SpatialThumbnail(width:w,height:h,rgb:shifted)
        XCTAssertGreaterThan(try XCTUnwrap(SurfaceTracking.cameraShapeCorrelation(a,b,x:20,y:16,referenceX:22,referenceY:16)),0.99)
        XCTAssertLessThan(try XCTUnwrap(SurfaceTracking.cameraShapeCorrelation(a,b,x:20,y:16,referenceX:20,referenceY:16)),0.95)
        let flat = SpatialThumbnail(width:w,height:h,rgb:Array(repeating:0.2,count:w*h*3))
        XCTAssertNil(SurfaceTracking.cameraShapeCorrelation(flat,flat,x:20,y:16,referenceX:20,referenceY:16))
    }

    func testCameraMeasurementRefinesFractionalGeometryUnderExposureChange() throws {
        let w=40,h=32
        func image(_ dx: Double,_ dy: Double,_ ev: Double) -> SpatialThumbnail {
            var rgb=[Float]()
            for y in 0..<h { for x in 0..<w {
                let xx=Double(x)-dx,yy=Double(y)-dy
                let level=Float(pow(2,-3+0.3*sin(xx*0.5)+0.25*cos(yy*0.37)+0.2*sin(xx*0.71+yy*0.29)+ev))
                rgb += [level,level*0.8,level*0.6]
            } }
            return .init(width:w,height:h,rgb:rgb)
        }
        let a=image(0,0,0),b=image(0.5,0.25,0.2)
        let q=try XCTUnwrap(SurfaceTracking.cameraRefinedPoint(a,b,x:20,y:16,referenceX:20,referenceY:16))
        XCTAssertLessThan(hypot(q.0-20.5,q.1-16.25),0.4)
        let flat=SpatialThumbnail(width:w,height:h,rgb:Array(repeating:0.2,count:w*h*3))
        XCTAssertNil(SurfaceTracking.cameraRefinedPoint(flat,flat,x:20,y:16,referenceX:20,referenceY:16))
    }

    func testScaledCameraSupportRetainsKnownMotionAndExposureGeometry() throws {
        let w=80,h=64
        var seed:UInt64=721,base=[Float]()
        for _ in 0..<40*32 {
            seed=seed &* 6364136223846793005 &+ 1
            let y=Float((seed >> 32)%1000)/10000+0.08
            base += [y,y*0.8,y*0.6]
        }
        var a=[Float](),b=[Float]()
        for y in 0..<h { for x in 0..<w { for c in 0..<3 {
            a.append(base[((y/2)*40+x/2)*3+c])
            b.append(base[((y/2)*40+max(0,x-4)/2)*3+c]*Float(pow(2,0.4)))
        } } }
        let source=SpatialThumbnail(width:w,height:h,rgb:a),reference=SpatialThumbnail(width:w,height:h,rgb:b)
        XCTAssertGreaterThan(try XCTUnwrap(SurfaceTracking.cameraShapeCorrelation(source,reference,x:40,y:32,referenceX:44,referenceY:32,half:12)),0.99)
        XCTAssertLessThan(try XCTUnwrap(SurfaceTracking.cameraShapeCorrelation(source,reference,x:40,y:32,referenceX:40,referenceY:32,half:12)),0.95)
        XCTAssertNil(SurfaceTracking.cameraShapeCorrelation(source,reference,x:40,y:32,referenceX:44,referenceY:32,half:13))
    }

}
