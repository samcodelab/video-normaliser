import XCTest
@testable import FrankLuma

final class CommonIlluminationTests: XCTestCase {
    func testRGBStepMeasuresPersistentResponseAndRejectsUnevenOrUnobservableFootprints() {
        let source = (0..<75).map { 0.12 + Double($0 % 11)*0.008 }
        let gains = [0.2, -0.1, 0.35]
        let shifted = source.enumerated().map { $0.element*exp2(gains[$0.offset%3]) }
        let evidence = CommonIlluminationComponent.stepPixels(before: source, after: shifted)
        XCTAssertNil(evidence.rejection)
        for c in 0..<3 { XCTAssertEqual(evidence.channelExcursion[c], gains[c], accuracy: 1e-12) }
        var changedMaterial = shifted
        for i in 0..<30 { changedMaterial[i] *= 1.3 }
        XCTAssertNotNil(CommonIlluminationComponent.stepPixels(before: source, after: changedMaterial).rejection)
        var clipped = shifted; clipped[0] = 1
        XCTAssertEqual(CommonIlluminationComponent.stepPixels(before: source, after: clipped).rejection, "clippingOrDarkChannel")
        XCTAssertNotNil(CommonIlluminationComponent.stepPixels(before: [], after: []).rejection)
    }

    func testLowTexturePipelineCorroboratesLightingButRejectsConcurrentIntrinsicBrightening() {
        let flags = ["FRANKLUMA_COMMON_PULSE_LUMINANCE":"1","FRANKLUMA_COMMON_PULSE_DONORS":"4","FRANKLUMA_COMMON_PULSE_TOLERANCE":"0.04","FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_QUERIES":"1","FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_COLOUR_CLOCK":"1","FRANKLUMA_COMMON_PULSE_FLOW_DIAGNOSTICS":"0"]
        let saved = flags.keys.map { ($0,getenv($0).map { String(cString:$0) }) }
        for (key,value) in flags { setenv(key,value,1) }
        defer { for (key,value) in saved { if let value { setenv(key,value,1) } else { unsetenv(key) } } }
        let w = 128,h = 96,baseColour: [Float] = [0.08,0.16,0.24]
        var rgb = Array(repeating:baseColour,count:w*h).flatMap { $0 }
        var tracks: [TrackedSurfaceResidual.Track] = []
        for y in [12,36,60] { for x in [12,36,60,108] {
            for dy in -6...6 { for dx in -6...6 {
                let shade = Float(1+0.15*sin(Double(dx)*0.8)+0.06*cos(Double(dy)*0.6))
                for c in 0..<3 { rgb[((y+dy)*w+x+dx)*3+c] = baseColour[c]*shade }
            } }
            let observations = (0..<3).map { TrackedSurfaceResidual.Observation(frame:$0,x:x,y:y,level:0) }
            tracks.append(.init(identity:[],identityHalf:6,observations:observations))
        } }
        let base = SpatialThumbnail(width:w,height:h,rgb:rgb)
        let light: [Float] = [1.3,1.1,0.9]
        let lit = rgb.enumerated().map { $0.element*light[$0.offset%3] }
        func measured(_ middle: [Float],camera: Set<Int> = [1]) -> (accepted:Set<Int>,protected:Set<Int>) {
            var points = Set<Int>(),protected = Set<Int>()
            let samples = (0..<3).map { ExposureSample(time:Double($0),level:0,segment:0) }
            TrackedSurfaceResidual.pulseDiagnostics(samples:samples,images:[base,.init(width:w,height:h,rgb:middle),base],tracks:tracks,
                cameraGuided:true,cameraHalf:6,stationaryCameraFrames:camera,quietSourceProtected:{ observations,_,_,footprints,valid,_ in
                    XCTAssertEqual(footprints.count,3)
                    XCTAssertEqual(valid.count,25)
                    protected.insert(observations[1].y*w+observations[1].x)
                },lowTextureCertified:{ observations,_,_,_,_,_ in
                    points.insert(observations[1].y*w+observations[1].x)
                },certified:{ _,_,_ in })
            return (points,protected)
        }
        XCTAssertTrue(measured(lit).accepted.contains(78*w+90))
        var replaced = lit
        for y in 72...84 { for x in 84...96 { for c in 0..<3 { replaced[(y*w+x)*3+c] *= 1.25 } } }
        let replacement = measured(replaced)
        XCTAssertFalse(replacement.accepted.contains(78*w+90))
        XCTAssertFalse(replacement.protected.contains(78*w+90))
        var quietPatch = lit
        for y in 72...84 { for x in 84...96 { for c in 0..<3 { quietPatch[(y*w+x)*3+c] = rgb[(y*w+x)*3+c] } } }
        let quiet = measured(quietPatch)
        XCTAssertTrue(quiet.protected.contains(78*w+90),"Independently quiet source region remains protected during an external coloured lighting event")
        XCTAssertFalse(quiet.accepted.contains(78*w+90),"Protection must not authorize a colour-clock correction")
        XCTAssertFalse(measured(quietPatch,camera:[]).protected.contains(78*w+90))
        setenv("FRANKLUMA_COMMON_PULSE_LOW_TEXTURE_QUERIES","0",1)
        let guardOnly = measured(quietPatch)
        XCTAssertTrue(guardOnly.protected.contains(78*w+90))
        XCTAssertTrue(guardOnly.accepted.isEmpty,"Enabling protection must not activate low-texture correction queries")
        var changedQuietMaterial = quietPatch
        for y in 72...84 { for x in 84...96 {
            changedQuietMaterial[(y*w+x)*3] += 0.04
            changedQuietMaterial[(y*w+x)*3+2] -= Float(0.04*0.2126/0.0722)
        } }
        XCTAssertFalse(measured(changedQuietMaterial).protected.contains(78*w+90),"Equal-luminance colour replacement is not quiet-region evidence")
        var quietTexture = lit
        for y in 54...66 { for x in 102...114 { for c in 0..<3 { quietTexture[(y*w+x)*3+c] = rgb[(y*w+x)*3+c] } } }
        XCTAssertTrue(measured(quietTexture).protected.contains(60*w+108),"Source-stable textured correspondence can protect a region without enabling event queries")
        for y in 58...62 { for x in 106...110 { quietTexture[(y*w+x)*3] *= 1.1 } }
        XCTAssertFalse(measured(quietTexture).protected.contains(60*w+108),"Changed textured material is not quiet RGB evidence")
    }

    func testColourClockRequiresIndependentMeasuredChannelsAndRejectsMaterialReplacement() throws {
        let base = Array(repeating:[0.08,0.16,0.24],count:25).flatMap { $0 }
        let changedLight = base.enumerated().map { $0.element*[1.3,1.1,0.9][$0.offset%3] }
        let measured = CommonIlluminationComponent.pulseObservableRGB(before:base,middle:changedLight,after:base,alpha:0.4)
        XCTAssertNil(measured.rejection)
        XCTAssertTrue(CommonIlluminationComponent.pulseColourCorroborates(query:measured,donors:Array(repeating:measured,count:4)))
        XCTAssertFalse(CommonIlluminationComponent.pulseColourCorroborates(query:measured,donors:Array(repeating:measured,count:3)))
        let replacement = Array(repeating:[0.24,0.16,0.08],count:25).flatMap { $0 }
        let material = CommonIlluminationComponent.pulseObservableRGB(before:base,middle:replacement,after:base,alpha:0.4)
        XCTAssertFalse(CommonIlluminationComponent.pulseColourCorroborates(query:material,donors:Array(repeating:measured,count:4)))
        let sameColourReplacement = CommonIlluminationComponent.pulseObservableRGB(before:base,middle:changedLight.map { $0*1.25 },after:base,alpha:0.4)
        XCTAssertFalse(CommonIlluminationComponent.pulseColourCorroborates(query:sameColourReplacement,donors:Array(repeating:measured,count:4)))
        let quiet = CommonIlluminationComponent.pulseObservableRGB(before:base,middle:base,after:base,alpha:0.4)
        XCTAssertFalse(CommonIlluminationComponent.pulseColourCorroborates(query:measured,donors:Array(repeating:quiet,count:4)))
    }

    func testColourClockNeverInfersUnmeasuredBlueFromRedGreenDonors() {
        let blue = Array(repeating:[0.0,0.1,0.2],count:25).flatMap { $0 }
        let redGreen = Array(repeating:[0.2,0.1,0.0],count:25).flatMap { $0 }
        let query = CommonIlluminationComponent.pulseObservableRGB(before:blue,middle:blue.map { $0*1.2 },after:blue,alpha:0.4)
        let donor = CommonIlluminationComponent.pulseObservableRGB(before:redGreen,middle:redGreen.map { $0*1.2 },after:redGreen,alpha:0.4)
        XCTAssertNil(query.rejection);XCTAssertNil(donor.rejection)
        XCTAssertNil(donor.channelExcursion[2])
        XCTAssertFalse(CommonIlluminationComponent.pulseColourCorroborates(query:query,donors:Array(repeating:donor,count:4)))
        XCTAssertTrue(CommonIlluminationComponent.pulseColourCorroborates(query:query,donors:Array(repeating:query,count:4)))
    }

    func testLowTexturePhotometryRequiresIndependentCameraAndRejectsOcclusionOrMaterialChange() throws {
        let base = Array(repeating:[0.08,0.16,0.24],count:169).flatMap { $0 }
        func measure(_ middle: [Double],camera: Bool = true) -> CommonIlluminationComponent.MaskedPulseEvidence {
            CommonIlluminationComponent.pulseLowTextureLuminancePixels(before:base,middle:middle,after:base,alpha:0.4,stationaryCameraSupported:camera)
        }
        let flash = measure(base.map { $0*1.2 })
        XCTAssertNil(flash.rejection)
        XCTAssertEqual(try XCTUnwrap(flash.excursion),log2(1.2),accuracy:1e-10)
        XCTAssertEqual(flash.validPixels.count,25)
        XCTAssertEqual(measure(base,camera:false).rejection,"unsupportedStationaryCamera")
        var occluded = base
        for y in 4...8 { for x in 4...8 { for c in 0..<3 { occluded[(y*13+x)*3+c] *= 1.5 } } }
        XCTAssertEqual(measure(occluded).rejection,"texturedOrOccludedRegion")
        let changedMaterial = Array(repeating:[0.24,0.16,0.08],count:169).flatMap { $0 }
        XCTAssertEqual(measure(changedMaterial).rejection,"changedLowTextureMaterialOrColour")
        let ramp = CommonIlluminationComponent.pulseLowTextureLuminancePixels(before:base.map { $0*exp2(-0.2) },middle:base,after:base.map { $0*exp2(0.3) },alpha:0.4,stationaryCameraSupported:true)
        XCTAssertEqual(try XCTUnwrap(ramp.excursion),0,accuracy:1e-10)
        XCTAssertNil(ramp.rejection)
        let quiet = CommonIlluminationComponent.pulseClock(excursions:[0,0,0,0],errors:[0,0,0,0],minimumDonors:4)
        XCTAssertEqual(quiet.state,.quiet)
        XCTAssertGreaterThan(abs(try XCTUnwrap(flash.excursion))+2*flash.heldError,0.01,"A quiet external clock must not authorize this strong local appearance change")
    }

    func testRankAwareSpectralPredictionKeepsUnobservableChannelGainsUnknown() throws {
        var base: [Double] = []
        for p in 0..<25 { let gain = 0.6+Double(p%4)*0.1;base += [0.2*gain,0.1*gain,0] }
        let result = CommonIlluminationComponent.pulseSpectralLuminancePixels(before:base,middle:base.map { $0*1.2 },after:base,alpha:0.4,rankAware:true)
        XCTAssertNil(result.rejection)
        XCTAssertNil(result.gains)
        XCTAssertEqual(result.identifiableRank,1)
        XCTAssertEqual(try XCTUnwrap(result.representativeExcursion),log2(1.2),accuracy:1e-10)
        XCTAssertLessThan(result.maximumPredictionUncertaintyEV,1e-10)
        var changed = base.map { $0*1.2 }
        for c in 0..<3 { changed[12*3+c] *= 1.3 }
        XCTAssertNotNil(CommonIlluminationComponent.pulseSpectralLuminancePixels(before:base,middle:changed,after:base,alpha:0.4,rankAware:true).rejection)
    }

    func testRankAwareSpectralPredictionRejectsUnseenHeldMaterialAndPreservesRamp() throws {
        var base: [Double] = []
        for p in 0..<25 { base += p/5 < 2 ? [0.2,0.1,0.05] : [0.05,0.1,0.2] }
        let unseen = CommonIlluminationComponent.pulseSpectralLuminancePixels(before:base,middle:base,after:base,alpha:0.4,rankAware:true)
        XCTAssertEqual(unseen.rejection,"unsupportedSpectralPrediction")
        let palette = [[0.2,0.1,0.05],[0.05,0.1,0.2]]
        let supported = (0..<25).flatMap { palette[$0%2] }
        let ramp = CommonIlluminationComponent.pulseSpectralLuminancePixels(before:supported.map { $0*exp2(-0.2) },middle:supported,after:supported.map { $0*exp2(0.3) },alpha:0.4,rankAware:true)
        XCTAssertNil(ramp.rejection)
        XCTAssertNil(ramp.gains)
        XCTAssertEqual(ramp.identifiableRank,2)
        XCTAssertEqual(try XCTUnwrap(ramp.representativeExcursion),0,accuracy:1e-10)
        let coloured = supported.enumerated().map { $0.element*[1.4,0.8,1.1][$0.offset%3] }
        let event = CommonIlluminationComponent.pulseSpectralLuminancePixels(before:supported,middle:coloured,after:supported,alpha:0.4,rankAware:true)
        XCTAssertNil(event.rejection)
        XCTAssertEqual(event.identifiableRank,2)
        XCTAssertNil(event.gains)
        XCTAssertGreaterThan(event.pixelExcursion.max()!-event.pixelExcursion.min()!,0.1)
    }

    func testFiniteKernelRequiresDisjointTransportedSupportsAndPreservesVFRExposure() throws {
        var rgb: [Double] = []
        for p in 0..<121 {
            let red = 0.1+0.04*sin(Double(p)*0.3)
            let green = 0.18+0.02*cos(Double(p))
            rgb.append(contentsOf:[red,green,0.08])
        }
        var points: [(x:Double,y:Double)] = []
        for p in 0..<121 { points.append((x:Double(10+p%11),y:Double(10+p/11))) }
        let shifted = points.map { (x:$0.x+0.25,y:$0.y+0.125) }
        let evidence = CommonIlluminationComponent.pulseKernelLuminancePixels(before:rgb.map { $0*0.8 },middle:rgb.map { $0*1.1 },after:rgb.map { $0*1.2 },footprints:[shifted,points,shifted],width:40,height:40,alpha:0.4)
        XCTAssertNil(evidence.rejection)
        XCTAssertEqual(try XCTUnwrap(evidence.excursion),log2(1.1)-0.6*log2(0.8)-0.4*log2(1.2),accuracy:1e-12)
        XCTAssertEqual(evidence.tapIndices.count,225)
        XCTAssertEqual(evidence.validTapIndices.count,225)
        XCTAssertEqual(evidence.tapWeights.reduce(0,+),25,accuracy:1e-12)
        let collapsed = Array(repeating:(x:10.25,y:10.125),count:121)
        let overlapping = CommonIlluminationComponent.pulseKernelLuminancePixels(before:rgb,middle:rgb,after:rgb,footprints:[collapsed,points,shifted],width:40,height:40,alpha:0.4)
        XCTAssertEqual(overlapping.rejection,"overlappingKernelHeldSupport")
        var changed = rgb
        for y in 3...7 { for x in 3...7 { for c in 0..<3 { changed[(y*11+x)*3+c] *= 1.7 } } }
        XCTAssertNotNil(CommonIlluminationComponent.pulseKernelLuminancePixels(before:rgb,middle:changed,after:rgb,footprints:[points,points,points],width:40,height:40,alpha:0.4).rejection)
        var clipped = rgb
        for y in 4...6 { for x in 4...6 { clipped[(y*11+x)*3] = 0.99 } }
        XCTAssertNotNil(CommonIlluminationComponent.pulseKernelLuminancePixels(before:rgb,middle:clipped,after:rgb,footprints:[points,points,points],width:40,height:40,alpha:0.4).rejection)
    }

    private typealias C = CommonIlluminationComponent

    private func fixture(count: Int = 144, variableTiming: Bool = false,
                         firstResponse: Double = 1, quiet: Bool = false) -> (times: [Double], tracks: [C.Track]) {
        let times = (0..<count).map { Double($0)/12 + (variableTiming ? 0.006*Double($0 % 3) : 0) }
        let tracks = (0..<32).map { identifier -> C.Track in
            let response = identifier == 0 ? firstResponse : 1.0
            return C.Track(observations: times.indices.map { frame in
                let phi = quiet ? 0 : 0.4*sin(2*Double.pi*times[frame]/2)
                let intrinsic = quiet && identifier < 4 ? 0.02*sin(Double(frame)*0.7) : 0
                return C.Observation(frame: frame, x: 7+(identifier % 8)*8, y: 7+(identifier/8)*8,
                                     level: Double(identifier)*0.03 + response*phi + 0.002*times[frame] + intrinsic)
            })
        }
        return (times, tracks)
    }

    func testSpectralMeterPredictsHeldMaterialDependentLuminance() throws {
        let palette = [[0.3,0.05,0.03],[0.04,0.25,0.03],[0.05,0.04,0.3]]
        let base = (0..<25).flatMap { palette[$0%3] },gains = [1.4,0.8,1.1]
        let middle = base.enumerated().map { $0.element*gains[$0.offset%3] }
        let result = CommonIlluminationComponent.pulseSpectralLuminancePixels(before:base,middle:middle,after:base,alpha:0.5)
        let fitted = try XCTUnwrap(result.gains)
        for c in 0..<3 { XCTAssertEqual(fitted[c],gains[c],accuracy:1e-8) }
        XCTAssertEqual(result.pixelExcursion.count,25)
        XCTAssertGreaterThan(result.pixelExcursion.max()!-result.pixelExcursion.min()!,0.4)
        XCTAssertNotNil(CommonIlluminationComponent.pulseLuminancePixels(before:base,middle:middle,after:base,alpha:0.5).rejection)
        var changed = middle
        for c in 0..<3 { changed[12*3+c] *= 1.2 }
        XCTAssertNil(CommonIlluminationComponent.pulseSpectralLuminancePixels(before:base,middle:changed,after:base,alpha:0.5).gains)
        let flat = Array(repeating:0.1,count:75)
        XCTAssertEqual(CommonIlluminationComponent.pulseSpectralLuminancePixels(before:flat,middle:flat,after:flat,alpha:0.5).rejection,"unidentifiableSpectralBasis")
    }

    func testSpectralMeterPreservesLinearVFRExposure() throws {
        let palette = [[0.3,0.05,0.03],[0.04,0.25,0.03],[0.05,0.04,0.3]]
        let base = (0..<25).flatMap { palette[$0%3] }
        let result = CommonIlluminationComponent.pulseSpectralLuminancePixels(before:base.map { $0*exp2(-0.2) },middle:base,after:base.map { $0*exp2(0.3) },alpha:0.4)
        XCTAssertEqual(try XCTUnwrap(result.representativeExcursion),0,accuracy:1e-8)
    }

    func testSmallObservedFootprintRequiresEveryPixelAndStrictHeldAgreement() throws {
        let base = (0..<27).map { 0.08+Double($0%7)*0.01 }
        let middle = base.map { $0*exp2(0.12) }
        let result = CommonIlluminationComponent.pulseMaskedLuminancePixels(before:base,middle:middle,after:base,alpha:0.5,tolerance:0.04,side:3)
        XCTAssertEqual(try XCTUnwrap(result.excursion),0.12,accuracy:1e-10)
        XCTAssertEqual(result.validPixels.count,9)
        var clipped = middle;clipped[0] = 1
        XCTAssertEqual(CommonIlluminationComponent.pulseMaskedLuminancePixels(before:base,middle:clipped,after:base,alpha:0.5,tolerance:0.04,side:3).rejection,"insufficientMaskedCoverage")
        var changed = middle
        for c in 0..<3 { changed[4*3+c] *= exp2(0.08) }
        XCTAssertNil(CommonIlluminationComponent.pulseMaskedLuminancePixels(before:base,middle:changed,after:base,alpha:0.5,tolerance:0.04,side:3).excursion)
        var halfChanged = middle
        for pixel in [0,2] { for c in 0..<3 { halfChanged[pixel*3+c] *= exp2(0.03) } }
        XCTAssertNil(CommonIlluminationComponent.pulseMaskedLuminancePixels(before:base,middle:halfChanged,after:base,alpha:0.5,tolerance:0.04,side:3).excursion)
    }

    func testActualFittedSinusoidalCorrectionPreservesAlreadyCorrectFullAndPartialOutput() throws {
        let fixture = fixture(variableTiming: true, firstResponse: 1.2)
        let configuration = C.Configuration(radius: 0.35, mode: .smooth)
        let estimate = C.estimate(times: fixture.times, tracks: fixture.tracks, configuration: configuration)[0]
        XCTAssertEqual(estimate.state, .supported)
        XCTAssertTrue(estimate.independentlyValidated)
        XCTAssertEqual(try XCTUnwrap(estimate.coefficient), 1.2, accuracy: 1e-8)
        for strength in [0.25, 0.5, 1.0] {
            for spatial in [0.25, 0.5, 1.0] {
                // The global and local paths need not have the same coefficient.
                let globalCoefficient = 0.8*strength
                let desired = (1-spatial)*globalCoefficient + spatial*strength*estimate.coefficient!
                let global = zip(estimate.q, estimate.times).map { globalCoefficient*$0 + 0.14 + 0.004*$1 }
                let rendered = zip(estimate.q, estimate.times).map { desired*$0 - 0.11 + 0.009*$1 }
                let result = try XCTUnwrap(C.calibrate(estimate: estimate, renderedGain: rendered, globalGain: global,
                    strength: strength, spatial: spatial, configuration: configuration))
                XCTAssertTrue(result.independentlyValidated)
                XCTAssertEqual(result.renderedCoefficient, desired, accuracy: 1e-8)
                XCTAssertEqual(result.delta, Array(repeating: 0, count: estimate.q.count))
            }
        }
    }

    func testPartialSpatialRetainsGlobalComponentAndPrivateCalibration() throws {
        let fixture = fixture()
        let configuration = C.Configuration(radius: 0.35, mode: .smooth)
        let estimate = C.estimate(times: fixture.times, tracks: fixture.tracks, configuration: configuration)[0]
        let strength = 0.5, spatial = 0.4, globalCoefficient = 0.3, baselineCoefficient = 0.12
        let global = estimate.q.map { globalCoefficient*$0 }
        let rendered = zip(estimate.q, estimate.times).map { baselineCoefficient*$0 + 0.2 + 0.005*$1 }
        let result = try XCTUnwrap(C.calibrate(estimate: estimate, renderedGain: rendered, globalGain: global,
            strength: strength, spatial: spatial, configuration: configuration))
        let desired = (1-spatial)*globalCoefficient + spatial*strength*estimate.coefficient!
        for index in estimate.q.indices {
            XCTAssertEqual(rendered[index]+result.delta[index], desired*estimate.q[index]+0.2+0.005*estimate.times[index], accuracy: 1e-8)
        }
    }

    func testSupportedAbsenceRemovesOnlyCoupledAutomaticGain() throws {
        let fixture = fixture(firstResponse: 0)
        let configuration = C.Configuration(radius: 0.35, mode: .steady)
        let estimate = C.estimate(times: fixture.times, tracks: fixture.tracks, configuration: configuration)[0]
        XCTAssertEqual(estimate.state, .absent)
        XCTAssertEqual(estimate.coefficient, 0)
        let privateGain = estimate.times.map { 0.17+0.006*$0 }
        let rendered = zip(estimate.q, privateGain).map { 0.7*$0+$1 }
        let result = try XCTUnwrap(C.calibrate(estimate: estimate, renderedGain: rendered,
            globalGain: Array(repeating: 0, count: rendered.count), strength: 1, spatial: 1, configuration: configuration))
        for index in rendered.indices {
            XCTAssertEqual(rendered[index]+result.delta[index], privateGain[index], accuracy: 1e-8)
        }
    }

    func testQuietMovingAppearanceAndDisabledSlidersMakeNoAdditions() {
        let quiet = fixture(quiet: true)
        let configuration = C.Configuration(radius: 0.35, mode: .smooth)
        let estimates = C.estimate(times: quiet.times, tracks: quiet.tracks, configuration: configuration)
        XCTAssertTrue(estimates.allSatisfy { $0.state == .quiet && $0.q.allSatisfy { $0 == 0 } })
        XCTAssertNil(C.calibrate(estimate: estimates[0], renderedGain: Array(repeating: 0.2, count: quiet.times.count),
            globalGain: Array(repeating: 0, count: quiet.times.count), strength: 1, spatial: 1, configuration: configuration))
        let lit = fixture()
        let estimate = C.estimate(times: lit.times, tracks: lit.tracks, configuration: configuration)[0]
        let gains = estimate.q.map { 0.7*$0 }
        XCTAssertNil(C.calibrate(estimate: estimate, renderedGain: gains, globalGain: gains,
            strength: 0, spatial: 1, configuration: configuration))
        XCTAssertNil(C.calibrate(estimate: estimate, renderedGain: gains, globalGain: gains,
            strength: 1, spatial: 0, configuration: configuration))
    }

    func testUnknownMissingEdgesAndShortTrackCannotPassStrictEventValidation() {
        let fixture = fixture()
        let configuration = C.Configuration(radius: 0.35, mode: .smooth)
        var tracks = fixture.tracks
        tracks[0] = C.Track(observations: Array(tracks[0].observations.prefix(5)))
        let short = C.estimate(times: fixture.times, tracks: tracks, configuration: configuration)[0]
        XCTAssertFalse(short.independentlyValidated)
        XCTAssertNil(C.calibrate(estimate: short, renderedGain: short.q, globalGain: short.q,
            strength: 1, spatial: 1, configuration: configuration))
        // Each half-track is valid, but there is no observation of edge 72.
        let separated = fixture.tracks.flatMap { track in
            [C.Track(observations: Array(track.observations.prefix(72))),
             C.Track(observations: Array(track.observations.dropFirst(72)))]
        }
        XCTAssertTrue(C.estimate(times: fixture.times, tracks: separated, configuration: configuration).allSatisfy { $0.state == .unknown })
        let invalidTimes = Array(repeating: 0.0, count: fixture.times.count)
        XCTAssertTrue(C.estimate(times: invalidTimes, tracks: fixture.tracks, configuration: configuration).allSatisfy { $0.state == .unknown })
    }

    func testGainResponseRejectsInconsistentTemporalCoupling() {
        let configuration = C.Configuration(radius: 0.35, mode: .smooth)
        let x = (0..<48).map { 0.2*sin(Double($0)*0.6) }
        let intervals = x.indices.map { 0.06+0.01*Double($0 % 3) }
        let y = x.indices.map { ($0 < 24 ? 0.7 : -0.4)*x[$0] + 0.01*intervals[$0] }
        XCTAssertNil(C.validate(x: x, y: y, intervals: intervals,
            folds: [Array(0..<24), Array(24..<48)], configuration: configuration))
        XCTAssertNil(C.fit(x: Array(repeating: 0, count: 10), y: Array(repeating: 0, count: 10), intervals: Array(repeating: 0.1, count: 10)))
    }

    func testVFRGainFitSeparatesPhysicalDriftFromComponent() throws {
        let dt = (0..<48).map { 0.06+0.02*Double($0 % 3) }
        let x = dt.indices.map { 0.2*sin(Double($0)*0.6) }
        let y = zip(x, dt).map { 0.6*$0+0.025*$1 }
        let fitted = try XCTUnwrap(C.fit(x: x, y: y, intervals: dt))
        XCTAssertEqual(fitted.coefficient, 0.6, accuracy: 1e-12)
        XCTAssertEqual(fitted.drift, 0.025, accuracy: 1e-12)
    }

    private func absenceFixture() -> (times: [Double], global: [Double], psi: [Double], source: [Double]) {
        let times = (0..<144).map { Double($0)/12 + 0.006*Double($0 % 3) }
        let global = times.map { 0.2+0.003*$0+0.4*sin(2*Double.pi*$0/2) }
        let trend = ExposureMath.smoothTargets(times: times, levels: global, radius: 0.35, preserveShortRamps: true)
        let psi = zip(global, trend).map(-)
        // Preserved intrinsic source variation, with no imposed illumination.
        let source = times.enumerated().map { -2+0.005*$0.element+0.0001*sin(Double($0.offset)*0.7) }
        return (times, global, psi, source)
    }

    func testGainAbsenceFallbackPreservesIntrinsicSourceAndPrivateVFRGain() throws {
        let f = absenceFixture()
        let rendered = zip(f.psi, f.times).map { 0.7*$0+0.12+0.008*$1 }
        for mode in [NormalisationMode.smooth, .steady] {
            let configuration = C.Configuration(radius: 0.35, mode: mode)
            let result = try XCTUnwrap(C.calibrateAbsence(times: f.times, frames: Array(f.times.indices),
                sourceLevels: f.source, renderedGain: rendered, globalGain: f.global, automaticGlobal: f.global,
                strength: 0.5, spatial: 1, configuration: configuration))
            XCTAssertTrue(result.independentlyValidated)
            XCTAssertEqual(result.renderedCoefficient, 0.7, accuracy: 1e-8)
            for i in f.times.indices {
                XCTAssertEqual(f.source[i]+rendered[i]+result.delta[i], f.source[i]+0.12+0.008*f.times[i], accuracy: 1e-8)
            }
        }
    }

    func testGainAbsenceFallbackRejectsActualSourceLightingAndInconsistentGain() {
        let f = absenceFixture()
        let configuration = C.Configuration(radius: 0.35, mode: .smooth)
        let coupledSource = zip(f.psi, f.times).map { -2+0.6*$0+0.005*$1 }
        let gain = f.psi.map { 0.7*$0 }
        XCTAssertNil(C.calibrateAbsence(times: f.times, frames: Array(f.times.indices),
            sourceLevels: coupledSource, renderedGain: gain, globalGain: f.global, automaticGlobal: f.global,
            strength: 1, spatial: 1, configuration: configuration))
        let inconsistent = f.psi.enumerated().map { ($0.offset < 72 ? 0.7 : -0.4)*$0.element }
        XCTAssertNil(C.calibrateAbsence(times: f.times, frames: Array(f.times.indices),
            sourceLevels: f.source, renderedGain: inconsistent, globalGain: f.global, automaticGlobal: f.global,
            strength: 1, spatial: 1, configuration: configuration))
    }

    func testGainAbsenceFallbackKeepsIdealPartialGlobalRemainder() throws {
        let f = absenceFixture()
        let configuration = C.Configuration(radius: 0.35, mode: .steady)
        let spatial = 0.4
        let globalOnly = zip(f.psi, f.times).map { 0.6*$0+0.1+0.005*$1 }
        let rendered = zip(f.psi, f.times).map { (1-spatial)*0.6*$0+0.2+0.002*$1 }
        let result = try XCTUnwrap(C.calibrateAbsence(times: f.times, frames: Array(f.times.indices),
            sourceLevels: f.source, renderedGain: rendered, globalGain: globalOnly, automaticGlobal: f.global,
            strength: 0.5, spatial: spatial, configuration: configuration))
        XCTAssertEqual(result.globalCoefficient, 0.6, accuracy: 1e-8)
        XCTAssertEqual(result.delta, Array(repeating: 0, count: f.times.count))
    }

    func testGainAbsenceFallbackRequiresExcitationSeparateEventsAndEnabledControls() throws {
        let f = absenceFixture()
        var configuration = C.Configuration(radius: 0.35, mode: .smooth)
        let source = f.times.map { -2+0.005*$0 }
        let gain = f.psi.map { 0.7*$0 }
        for (strength, spatial) in [(0.0, 1.0), (1.0, 0.0)] {
            XCTAssertNil(C.calibrateAbsence(times: f.times, frames: Array(f.times.indices),
                sourceLevels: source, renderedGain: gain, globalGain: f.global, automaticGlobal: f.global,
                strength: strength, spatial: spatial, configuration: configuration))
        }
        XCTAssertNil(C.calibrateAbsence(times: f.times, frames: Array(f.times.indices),
            sourceLevels: source, renderedGain: gain, globalGain: f.global,
            automaticGlobal: Array(repeating: 0, count: f.times.count),
            strength: 1, spatial: 1, configuration: configuration))
        // A single invented automatic flash cannot validate on another event.
        var flash = Array(repeating: 0.0, count: f.times.count)
        flash[72] = 0.4
        let trend = ExposureMath.smoothTargets(times: f.times, levels: flash, radius: 0.35, preserveShortRamps: true)
        let flashGain = zip(flash, trend).map { 0.7*($0-$1) }
        XCTAssertNil(C.calibrateAbsence(times: f.times, frames: Array(f.times.indices),
            sourceLevels: source, renderedGain: flashGain, globalGain: flash, automaticGlobal: flash,
            strength: 1, spatial: 1, configuration: configuration))
        configuration.requireIndependentEvents = false
        let diagnostic = try XCTUnwrap(C.calibrateAbsence(times: f.times, frames: Array(f.times.indices),
            sourceLevels: source, renderedGain: flashGain, globalGain: flash, automaticGlobal: flash,
            strength: 1, spatial: 1, configuration: configuration))
        XCTAssertFalse(diagnostic.independentlyValidated)
    }

    func testEdgeDiagnosticsReportEveryExactFailureWithoutEarlyAbort() throws {
        let configuration = C.Configuration(radius: 0.35, mode: .smooth, minimumDonors: 4)
        let tracks = (0..<4).map { index -> C.Track in
            let changes = index < 2 ? [0.2, 0.2, 0.2] : [0.2, -0.2, 0.0]
            var levels = [0.0]
            for change in changes { levels.append(levels.last!+change) }
            return C.Track(observations: levels.indices.map {
                C.Observation(frame: $0, x: 7+10*index, y: 7, level: levels[$0])
            })
        }
        let rows = C.edgeDiagnostics(frameCount: 5, tracks: tracks, configuration: configuration)
        XCTAssertEqual(rows.map(\.frame), [1, 2, 3, 4])
        XCTAssertEqual(rows.map(\.rejection), [nil, .opposingSigns, .weakSpatialHalf, .insufficientQuorum])
        XCTAssertEqual(rows.map(\.candidateCount), [4, 4, 4, 0])
        XCTAssertEqual(rows.map(\.independentCount), [4, 4, 4, 0])
        XCTAssertEqual(try XCTUnwrap(rows[1].left), 0.2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(rows[1].right), -0.2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(rows[1].median), 0, accuracy: 1e-12)
        XCTAssertNil(rows[3].left)
        XCTAssertNil(rows[3].right)
        XCTAssertNil(rows[3].median)
    }

    func testDuplicatedDonorTrajectoriesDoNotInflateIndependentQuorum() {
        let configuration = C.Configuration(radius: 0.35, mode: .smooth, minimumDonors: 5)
        let tracks = (0..<4).map { index in
            C.Track(observations: (0..<3).map {
                C.Observation(frame: $0, x: 7+10*index, y: 7, level: Double($0)*0.2)
            })
        }
        let primary = C.edgeDiagnostics(frameCount: 3, tracks: tracks, configuration: configuration)
        let duplicated = C.edgeDiagnostics(frameCount: 3, tracks: tracks, additionalDonors: tracks, configuration: configuration)
        XCTAssertEqual(primary.map(\.candidateCount), [4, 4])
        XCTAssertEqual(duplicated.map(\.candidateCount), [8, 8])
        XCTAssertEqual(primary.map(\.independentCount), duplicated.map(\.independentCount))
        XCTAssertTrue(duplicated.allSatisfy { $0.rejection == .insufficientQuorum })
        XCTAssertEqual(primary.map(\.median), duplicated.map(\.median))
    }

    func testHypotheticalDisjointShortPairsCanExplainQuorumWithoutChangingEstimation() {
        let configuration = C.Configuration(radius: 0.35, mode: .smooth, minimumDonors: 4)
        let primary = (0..<2).map { index in
            C.Track(observations: (0..<3).map {
                C.Observation(frame: $0, x: 7+10*index, y: 7, level: Double($0)*0.2)
            })
        }
        let short = (2..<4).map { index in
            C.Track(observations: (0..<2).map {
                C.Observation(frame: $0, x: 7+10*index, y: 7, level: Double($0)*0.2)
            })
        }
        let before = C.estimate(times: [0, 0.1, 0.2], tracks: primary, configuration: configuration)
        let ordinary = C.edgeDiagnostics(frameCount: 3, tracks: primary+short, configuration: configuration)
        let hypothetical = C.edgeDiagnostics(frameCount: 3, tracks: primary, additionalDonors: short, configuration: configuration)
        XCTAssertEqual(ordinary.map(\.independentCount), [2, 2])
        XCTAssertTrue(ordinary.allSatisfy { $0.rejection == .insufficientQuorum })
        XCTAssertEqual(hypothetical.map(\.independentCount), [4, 2])
        XCTAssertNil(hypothetical[0].rejection)
        XCTAssertEqual(hypothetical[1].rejection, .insufficientQuorum)
        let after = C.estimate(times: [0, 0.1, 0.2], tracks: primary, configuration: configuration)
        XCTAssertTrue(before.allSatisfy { $0.state == .unknown })
        XCTAssertEqual(before.map(\.state), after.map(\.state))
        XCTAssertEqual(before.map(\.q), after.map(\.q))
    }
    func testSupportedRunsRecoverEvidenceWithoutBridgingMissingTransitions() throws {
        let original = fixture(count: 288, variableTiming: true)
        let split = 144
        let separated = original.tracks.flatMap { track in
            [C.Track(observations: Array(track.observations.prefix(split))),
             C.Track(observations: Array(track.observations.dropFirst(split)))]
        }
        var configuration = C.Configuration(radius: 0.35, mode: .smooth)
        XCTAssertTrue(C.estimate(times: original.times, tracks: separated, configuration: configuration)
            .allSatisfy { $0.state == .unknown })
        configuration.allowSupportedRuns = true
        let estimates = C.estimate(times: original.times, tracks: separated, configuration: configuration)
        XCTAssertTrue(estimates.allSatisfy { $0.state == .supported && $0.independentlyValidated })
        for (offset, range) in [0..<split, split..<original.times.count].enumerated() {
            let localTracks = original.tracks.map { track in
                C.Track(observations: range.map { frame in
                    let observation = track.observations[frame]
                    return C.Observation(frame: frame-range.lowerBound, x: observation.x,
                        y: observation.y, level: observation.level)
                })
            }
            let local = C.estimate(times: Array(original.times[range]), tracks: localTracks,
                configuration: configuration)[0]
            let recovered = estimates[offset]
            XCTAssertEqual(recovered.q, local.q)
            XCTAssertEqual(try XCTUnwrap(recovered.coefficient), try XCTUnwrap(local.coefficient), accuracy: 1e-10)
            let gains = zip(recovered.q, recovered.times).map { $0 + 0.2 + 0.01*$1 }
            let calibrated = try XCTUnwrap(C.calibrate(estimate: recovered, renderedGain: gains, globalGain: gains,
                strength: 1, spatial: 1, configuration: configuration))
            XCTAssertEqual(calibrated.delta, Array(repeating: 0, count: gains.count))
        }
        // A sole long query cannot certify the missing edge from itself.
        let crossing = C.estimate(times: original.times, tracks: separated+[original.tracks[0]],
            configuration: configuration).last!
        XCTAssertEqual(crossing.state, .unknown)
    }

    func testSupportedRunsDoNotBorrowExcitationFromOtherRun() {
        let lit = fixture(count: 144)
        let quiet = fixture(count: 144, quiet: true)
        let tracks = lit.tracks + quiet.tracks.map { track in
            C.Track(observations: track.observations.map {
                C.Observation(frame: $0.frame+144, x: $0.x, y: $0.y, level: $0.level+3)
            })
        }
        let times = (0..<288).map { Double($0)/12 }
        let configuration = C.Configuration(radius: 0.35, mode: .steady, allowSupportedRuns: true)
        let estimates = C.estimate(times: times, tracks: tracks, configuration: configuration)
        XCTAssertTrue(estimates.prefix(32).allSatisfy { $0.state == .supported })
        XCTAssertTrue(estimates.suffix(32).allSatisfy { $0.state == .quiet && $0.q.allSatisfy { $0 == 0 } })
    }

    func testMaskedPulseUsesOnlyObservablePixelsAndStillChecksHeldInterior() {
        let source = (0..<75).map { 0.07+Double(($0*37)%101)/1000 }
        var before = source,middle = source.map { $0*exp2(0.3) },after = source
        before[0] = 1; middle[0] = 1; after[0] = 1
        let evidence = C.pulseMaskedLuminancePixels(before:before,middle:middle,after:after,alpha:0.35)
        XCTAssertNil(evidence.rejection)
        XCTAssertEqual(evidence.validPixels.count,24)
        XCTAssertFalse(evidence.validPixels.contains(0))
        XCTAssertEqual(evidence.excursion!,0.3,accuracy:1e-10)
        before[0] = -0.001
        let negative = C.pulseMaskedLuminancePixels(before:before,middle:middle,after:after,alpha:0.35)
        XCTAssertNil(negative.rejection)
        XCTAssertEqual(negative.validPixels,evidence.validPixels)
        before[0] = 1
        for c in 0..<3 { middle[12*3+c] *= 1.5 }
        XCTAssertEqual(C.pulseMaskedLuminancePixels(before:before,middle:middle,after:after,alpha:0.35).rejection,"nonuniformMaskedInteriorResponse")
        middle = source.map { $0*exp2(0.3) }
        for pixel in 0..<10 { middle[pixel*3] = 1 }
        XCTAssertEqual(C.pulseMaskedLuminancePixels(before:source,middle:middle,after:source,alpha:0.35).rejection,"insufficientMaskedCoverage")
        middle = source.map { $0*exp2(0.3) }
        for pixel in 0..<10 { for c in 0..<3 { middle[pixel*3+c] *= 1.15 } }
        XCTAssertEqual(C.pulseMaskedLuminancePixels(before:source,middle:middle,after:source,alpha:0.35).rejection,"nonuniformMaskedHeldResponse")
        middle[0] = .nan
        XCTAssertEqual(C.pulseMaskedLuminancePixels(before:source,middle:middle,after:source,alpha:0.35).rejection,"invalidMaskedShapeTimeOrRGB")
    }

    func testLargerPulseFootprintsRetainHeldAndInteriorChecks() {
        for side in [5,9,13] {
            let source = (0..<side*side*3).map { 0.08+Double(($0*37)%101)/1000 }
            let middle = source.map { $0*exp2(0.3) }
            let evidence = C.pulseLuminancePixels(before:source,middle:middle,after:source,alpha:0.35,side:side)
            XCTAssertNil(evidence.rejection)
            XCTAssertEqual(evidence.channelExcursion[0],0.3,accuracy:1e-10)
            var changed = middle
            for y in 0..<side/2 { for x in 0..<side { for c in 0..<3 { changed[(y*side+x)*3+c] *= 1.15 } } }
            XCTAssertNotNil(C.pulseLuminancePixels(before:source,middle:changed,after:source,alpha:0.35,side:side).rejection)
            changed = middle
            let center = ((side/2)*side+side/2)*3
            for c in 0..<3 { changed[center+c] *= 2 }
            XCTAssertNotNil(C.pulseLuminancePixels(before:source,middle:changed,after:source,alpha:0.35,side:side).rejection)
        }
        let source = Array(repeating:0.1,count:13*13*3)
        XCTAssertNotNil(C.pulseLuminancePixels(before:source,middle:source,after:source,alpha:0.5,side:12).rejection)
    }

    func testPulsePixelsRespectPhysicalTimingAndSeparateColorGainsFromTexture() {
        let texture = (0..<75).map { 0.08+0.002*Double($0) }
        let times = [0.0,0.07,0.2], alpha = 0.35
        let pulse = [0.3,-0.1,0.2]
        let before = texture
        let middle = texture.enumerated().map { $0.element*pow(2,0.4*times[1]+pulse[$0.offset%3]) }
        let after = texture.map { $0*pow(2,0.4*times[2]) }
        let result = C.pulsePixels(before: before,middle: middle,after: after,alpha: alpha)
        XCTAssertNil(result.rejection)
        for channel in 0..<3 { XCTAssertEqual(result.channelExcursion[channel],pulse[channel],accuracy: 1e-12) }
        let ramp = texture.map { $0*pow(2,0.4*times[1]) }
        let quiet = C.pulsePixels(before: before,middle: ramp,after: after,alpha: alpha)
        XCTAssertNil(quiet.rejection)
        XCTAssertTrue(quiet.channelExcursion.allSatisfy { abs($0) < 1e-12 })
        // Uniform changing shading is deliberately indistinguishable here.
        // It still needs independent material donors before illumination use.
    }

    func testPulsePixelsRejectSpatialShapeChangesIncludingUnusedCenter() {
        let texture = (0..<75).map { 0.08+0.002*Double($0) }
        var shape = texture
        for pixel in 0..<25 where pixel/5 < 2 {
            for channel in 0..<3 { shape[pixel*3+channel] *= pow(2,0.15) }
        }
        XCTAssertEqual(C.pulsePixels(before: texture,middle: shape,after: texture,alpha: 0.5).rejection,
            "nonuniformHeldResponse")
        shape = texture
        for channel in 0..<3 { shape[12*3+channel] *= 2 }
        XCTAssertEqual(C.pulsePixels(before: texture,middle: shape,after: texture,alpha: 0.5).rejection,
            "nonuniformInteriorResponse")
    }

    func testPulsePixelsRejectInvalidTimeClippingAndUnobservableDarkChannels() {
        let texture = Array(repeating: 0.2,count: 75)
        XCTAssertEqual(C.pulsePixels(before: texture,middle: texture,after: texture,alpha: 0).rejection,
            "invalidShapeOrTime")
        for value in [Double.nan,0.001,0.99] {
            var damaged = texture;damaged[7] = value
            XCTAssertEqual(C.pulsePixels(before: texture,middle: damaged,after: texture,alpha: 0.5).rejection,
                "clippingOrDarkChannel")
        }
    }

    func testLuminancePulseCanObserveSaturatedColorWithDarkIndividualChannels() {
        let before = (0..<25).flatMap { pixel in [0.2+0.002*Double(pixel),0.001,0.002] }
        let after = before.map { $0*pow(2,0.08) }
        let middle = before.map { $0*pow(2,0.35+0.028) }
        XCTAssertNotNil(C.pulsePixels(before: before,middle: middle,after: after,alpha: 0.35).rejection)
        let evidence = C.pulseLuminancePixels(before: before,middle: middle,after: after,alpha: 0.35)
        XCTAssertNil(evidence.rejection)
        for value in evidence.channelExcursion { XCTAssertEqual(value,0.35,accuracy: 1e-12) }
    }

    func testLuminancePulseDoesNotInterpretConstantEnergyColorVariationAsExposure() {
        let before = Array(repeating: [0.2,0.1,0.1],count: 25).flatMap { $0 }
        var middle = before
        for pixel in 0..<25 where pixel/5 < 2 {
            middle[pixel*3] += 0.08
            middle[pixel*3+1] -= 0.08*0.2126/0.7152
        }
        XCTAssertNotNil(C.pulsePixels(before: before,middle: middle,after: before,alpha: 0.5).rejection)
        let evidence = C.pulseLuminancePixels(before: before,middle: middle,after: before,alpha: 0.5)
        XCTAssertNil(evidence.rejection)
        XCTAssertTrue(evidence.channelExcursion.allSatisfy { abs($0) < 1e-12 })
        let dark = Array(repeating: 0.001,count: 75)
        XCTAssertNotNil(C.pulseLuminancePixels(before: dark,middle: dark,after: dark,alpha: 0.5).rejection)
        middle[0] = 0.99
        XCTAssertEqual(C.pulseLuminancePixels(before: before,middle: middle,after: before,alpha: 0.5).rejection,
            "invalidOrClippedRGB")
    }

    func testTonePulseHeldPredictionAndChangedInterior() throws {
        let levels = (0..<25).map { [0.08,0.12,0.20,0.30][($0%5+$0/5)%4] }
        let before = levels.flatMap { [$0,$0,$0] }
        let middle = levels.flatMap { value -> [Double] in
            let y = pow(2,0.3+1.2*log2(value)); return [y,y,y]
        }
        let e = C.pulseToneLuminancePixels(before:before,middle:middle,after:before,alpha:0.3)
        XCTAssertNil(e.rejection)
        XCTAssertEqual(try XCTUnwrap(e.slope),1.2,accuracy:1e-8)
        XCTAssertEqual(try XCTUnwrap(e.intercept),0.3,accuracy:1e-8)
        XCTAssertEqual(e.pixelExcursion.count,25)
        var changed = middle
        for c in 0..<3 { changed[12*3+c] *= 2 }
        XCTAssertNotNil(C.pulseToneLuminancePixels(before:before,middle:changed,after:before,alpha:0.3).rejection)
    }

    func testTonePulsePreservesVFRLinearExposureAndRejectsFlatTexture() throws {
        let levels = (0..<25).map { [0.08,0.12,0.20,0.30][($0%5+$0/5)%4] }
        let before = levels.flatMap { [$0,$0,$0] }
        let after = before.map { $0*pow(2,0.4) }, middle = before.map { $0*pow(2,0.4*0.3) }
        let e = C.pulseToneLuminancePixels(before:before,middle:middle,after:after,alpha:0.3)
        XCTAssertNil(e.rejection)
        XCTAssertEqual(try XCTUnwrap(e.representativeExcursion),0,accuracy:1e-8)
        let flat = Array(repeating:0.2,count:75)
        XCTAssertEqual(C.pulseToneLuminancePixels(before:flat,middle:flat,after:flat,alpha:0.5).rejection,"insufficientToneRange")
    }

    func testWideToneSupportStillChecksHeldRegionsAndInterior() throws {
        let side = 13
        let levels = (0..<side*side).map { [0.08,0.12,0.20,0.30][($0%side+$0/side)%4] }
        let a = levels.flatMap { [$0,$0,$0] }
        var b = levels.flatMap { value -> [Double] in
            let y = pow(2,0.3+1.2*log2(value));return [y,y,y]
        }
        let e = C.pulseToneLuminancePixels(before:a,middle:b,after:a,alpha:0.5,side:side)
        XCTAssertNil(e.rejection)
        XCTAssertEqual(e.pixelExcursion.count,side*side)
        for pixel in 0..<side*side where pixel/side < side/2 {
            for channel in 0..<3 { b[pixel*3+channel] *= 1.3 }
        }
        XCTAssertNotNil(C.pulseToneLuminancePixels(before:a,middle:b,after:a,alpha:0.5,side:side).rejection)
        XCTAssertNotNil(C.pulseToneLuminancePixels(before:a,middle:a,after:a,alpha:0.5,side:12).rejection)
    }

    func testToneOverlapRequiresBroadHeldSupportRatherThanEveryExtreme() throws {
        var levels = (0..<25).map { [0.08,0.12,0.20,0.30][($0%5+$0/5)%4] }
        levels[0] = 0.07
        let a = levels.flatMap { [$0,$0,$0] }
        var b = levels.flatMap { value -> [Double] in
            let y = pow(2,0.3+1.2*log2(value));return [y,y,y]
        }
        XCTAssertEqual(C.pulseToneLuminancePixels(before:a,middle:b,after:a,alpha:0.5).rejection,"toneExtrapolation")
        let e = C.pulseToneLuminancePixels(before:a,middle:b,after:a,alpha:0.5,overlapOnly:true)
        XCTAssertNil(e.rejection)
        XCTAssertEqual(try XCTUnwrap(e.slope),1.2,accuracy:1e-8)
        for pixel in 0..<10 { for channel in 0..<3 { b[pixel*3+channel] *= 1.5 } }
        XCTAssertNotNil(C.pulseToneLuminancePixels(before:a,middle:b,after:a,alpha:0.5,overlapOnly:true).rejection)
    }

    func testPulseClockDistinguishesQuietFromMissingAndConflictingEvidence() {
        let quiet = C.pulseClock(excursions:[0.001,-0.001,0.002,-0.002],errors:[0.001,0.001,0.001,0.001])
        XCTAssertEqual(quiet.state,.quiet)
        XCTAssertNotNil(quiet.excursion)
        for values in [[Double](),[0,0,0],[-0.2,-0.2,0.2,0.2],[0.02,0.02,0.02,0.02]] {
            let e = C.pulseClock(excursions:values,errors:Array(repeating:0,count:values.count))
            XCTAssertEqual(e.state,.unknown)
            XCTAssertNil(e.excursion)
        }
        XCTAssertEqual(C.pulseClock(excursions:[0,0,0,0],errors:[0.02,0,0,0]).state,.unknown)
        let flash = C.pulseClock(excursions:[0.3,0.31,0.32,0.29],errors:Array(repeating:0.01,count:4))
        XCTAssertEqual(flash.state,.event)
        XCTAssertEqual(flash.excursion!,0.305,accuracy:1e-8)
    }

    func testSpatialPulsePlanePredictsIndependentPixelsAndRejectsChangedCenter() throws {
        let a = (0..<25).flatMap { i -> [Double] in
            let y = 0.08+Double((i*7)%13)*0.005;return [y,y,y]
        }
        var b = a
        for i in 0..<25 {
            let gain = pow(2,0.2+0.1*Double(i%5-2)/2-0.08*Double(i/5-2)/2)
            for c in 0..<3 { b[i*3+c] *= gain }
        }
        XCTAssertNotNil(C.pulseLuminancePixels(before:a,middle:b,after:a,alpha:0.3).rejection)
        let e = C.pulsePlaneLuminancePixels(before:a,middle:b,after:a,alpha:0.3)
        XCTAssertNil(e.rejection)
        for (got,want) in zip(e.coefficients,[0.2,0.1,-0.08]) { XCTAssertEqual(got,want,accuracy:1e-8) }
        for c in 0..<3 { b[12*3+c] *= pow(2,0.1) }
        XCTAssertNotNil(C.pulsePlaneLuminancePixels(before:a,middle:b,after:a,alpha:0.3).rejection)
    }

    func testSpatialPlanePreservesLinearVFRLightAndRejectsDeformation() {
        let a = (0..<25).flatMap { i -> [Double] in
            let y = 0.08+Double((i*7)%13)*0.005;return [y,y,y]
        }
        let c = a.map { $0*pow(2,0.4) },b = a.map { $0*pow(2,0.4*0.3) }
        let e = C.pulsePlaneLuminancePixels(before:a,middle:b,after:c,alpha:0.3)
        XCTAssertNil(e.rejection)
        XCTAssertTrue(e.pixelExcursion.allSatisfy { abs($0)<1e-8 })
        var changed = a
        for i in 0..<25 { for c in 0..<3 { changed[i*3+c] *= pow(2,i%2 == 0 ? 0.2 : -0.2) } }
        XCTAssertNotNil(C.pulsePlaneLuminancePixels(before:a,middle:changed,after:a,alpha:0.5).rejection)
    }

    func testObservableRGBKeepsDarkChannelUnknownAndPredictsColourResponse() throws {
        let a = (0..<25).flatMap { i -> [Double] in [i%2 == 0 ? 0.06 : 0.25,0.03,0.00001] }
        var b = a
        for i in 0..<25 { b[i*3] *= pow(2,0.6);b[i*3+1] *= pow(2,-0.3) }
        XCTAssertNotNil(C.pulseLuminancePixels(before:a,middle:b,after:a,alpha:0.5).rejection)
        let e = C.pulseObservableRGB(before:a,middle:b,after:a,alpha:0.5)
        XCTAssertNil(e.rejection)
        XCTAssertEqual(try XCTUnwrap(e.channelExcursion[0]),0.6,accuracy:1e-8)
        XCTAssertEqual(try XCTUnwrap(e.channelExcursion[1]),-0.3,accuracy:1e-8)
        XCTAssertNil(e.channelExcursion[2])
        XCTAssertGreaterThan(e.minimumMeasuredLuminanceCoverage,0.98)
        b[12*3] *= pow(2,0.2)
        XCTAssertNotNil(C.pulseObservableRGB(before:a,middle:b,after:a,alpha:0.5).rejection)
    }

    func testObservableRGBRejectsSignificantUnresolvedEnergyAndPreservesVFRRamp() {
        let low = (0..<25).flatMap { _ in [0.006,0.006,0.004] }
        XCTAssertEqual(C.pulseObservableRGB(before:low,middle:low,after:low,alpha:0.5).rejection,"insufficientMeasuredLuminanceCoverage")
        let a = (0..<25).flatMap { _ in [0.1,0.03,0.00001] }
        let c = a.map { $0*pow(2,0.4) },b = a.map { $0*pow(2,0.4*0.3) }
        let e = C.pulseObservableRGB(before:a,middle:b,after:c,alpha:0.3)
        XCTAssertNil(e.rejection)
        XCTAssertEqual(e.representativeExcursion ?? 99,0,accuracy:1e-8)
    }

    func testAffineLinearResponsePredictsAdditiveLightAndRejectsChangedInterior() throws {
        let levels=(0..<25).map { [0.04,0.08,0.15,0.25][($0%5+$0/5)%4] }
        let a=levels.flatMap { [$0,$0,$0] }
        var b=a.map { 1.2*$0+0.02 }
        XCTAssertNotNil(C.pulseLuminancePixels(before:a,middle:b,after:a,alpha:0.5).rejection)
        let e=C.pulseLinearLuminancePixels(before:a,middle:b,after:a,alpha:0.5)
        XCTAssertNil(e.rejection)
        XCTAssertEqual(try XCTUnwrap(e.gain),1.2,accuracy:1e-8)
        XCTAssertEqual(try XCTUnwrap(e.offset),0.02,accuracy:1e-8)
        for channel in 0..<3 { b[12*3+channel] *= pow(2,0.2) }
        XCTAssertNotNil(C.pulseLinearLuminancePixels(before:a,middle:b,after:a,alpha:0.5).rejection)
    }

    func testAffineLinearResponsePreservesVFRRampAndRejectsWeakVariation() {
        let a=(0..<25).flatMap { i -> [Double] in let y=[0.04,0.08,0.15,0.25][(i%5+i/5)%4];return [y,y,y] }
        let c=a.map { $0*pow(2,0.4) },b=a.map { $0*pow(2,0.4*0.3) }
        let e=C.pulseLinearLuminancePixels(before:a,middle:b,after:c,alpha:0.3)
        XCTAssertNil(e.rejection)
        XCTAssertEqual(e.representativeExcursion ?? 99,0,accuracy:1e-8)
        let flat=Array(repeating:0.1,count:75)
        XCTAssertNotNil(C.pulseLinearLuminancePixels(before:flat,middle:flat,after:flat,alpha:0.5).rejection)
    }

    func testArithmeticRadianceReferencePreservesAdditiveVFRRamp() throws {
        let base=(0..<25).flatMap { i -> [Double] in
            let y=[0.015,0.04,0.12,0.3][(i%5+i/5)%4];return [y,y,y]
        }
        let after=base.map { 1.4*$0+0.08 },alpha=0.3
        let reference=zip(base,after).map { (1-alpha)*$0.0+alpha*$0.1 }
        let quiet=C.pulseLinearLuminancePixels(before:base,middle:reference,after:after,alpha:alpha,reference:.arithmeticRadiance)
        XCTAssertNil(quiet.rejection)
        XCTAssertEqual(try XCTUnwrap(quiet.representativeExcursion),0,accuracy:1e-8)
        let pulse=reference.map { 1.15*$0+0.015 }
        let evidence=C.pulseLinearLuminancePixels(before:base,middle:pulse,after:after,alpha:alpha,reference:.arithmeticRadiance)
        XCTAssertNil(evidence.rejection)
        XCTAssertEqual(try XCTUnwrap(evidence.gain),1.15,accuracy:1e-8)
        XCTAssertEqual(try XCTUnwrap(evidence.offset),0.015,accuracy:1e-8)
        var changed=pulse
        for channel in 0..<3 { changed[36+channel] *= 1.3 }
        XCTAssertNotNil(C.pulseLinearLuminancePixels(before:base,middle:changed,after:after,alpha:alpha,reference:.arithmeticRadiance).rejection)
    }

}
