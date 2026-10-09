import XCTest
@testable import FrankLuma

final class PersistentLocalFlashTests: XCTestCase {
    func testBasisReproducesConstantInteriorGainWithoutAmplifyingWeakAppearance() {
        let w = 25, h = 25
        func raw(_ stride: Int) -> [[PersistentLightingSolver.Weight]] {
            var values = Array(repeating: [PersistentLightingSolver.Weight](),count: w*h)
            var index = 0
            for y in Swift.stride(from: 6,through: 18,by: stride) {
                for x in Swift.stride(from: 6,through: 18,by: stride) {
                    for dy in -5...5 { for dx in -5...5 {
                        values[(y+dy)*w+x+dx].append(.init(index: index,
                            value: (1-Double(abs(dx))/6)*(1-Double(abs(dy))/6)))
                    } }
                    index += 1
                }
            }
            return values
        }
        for spacing in [3,6] {
            let input = raw(spacing)
            var confidence = Array(repeating: 1.0,count: w*h)
            confidence[12*w+12] = 1e-9
            let result = PersistentLightingBasis.normalize(input,width: w,height: h,compatibility: confidence)
            for y in 5...19 { for x in 5...19 where x != 12 || y != 12 {
                XCTAssertEqual(result[y*w+x].reduce(0) { $0+$1.value },1,accuracy: 1e-12)
            } }
            XCTAssertEqual(result[12*w+12].reduce(0) { $0+$1.value },1e-9,accuracy: 1e-15)
            XCTAssertTrue(result[0].isEmpty)
            XCTAssertEqual(result[w+12].reduce(0) { $0+$1.value },1.0/3,accuracy: 1e-12)
            // Duplicating a donor changes interpolation but not constant gain.
            let duplicated = input.map { $0+$0 }
            let again = PersistentLightingBasis.normalize(duplicated,width: w,height: h,compatibility: confidence)
            for p in result.indices {
                XCTAssertEqual(result[p].reduce(0) { $0+$1.value },again[p].reduce(0) { $0+$1.value },accuracy: 1e-12)
            }
        }
    }

    func testTrackedResidualPreservesLinearLightingRampIncludingEndpoints() {
        let w = 96, h = 56
        let samples: [ExposureSample] = (0..<11).map { frame in
            var rgb = [Float]()
            for y in 0..<h { for x in 0..<w {
                let texture = 0.22*sin(Double(x)*0.9)*cos(Double(y)*0.7)+0.06*cos(Double(x)*1.7+Double(y)*0.4)
                let gain = exp2(texture+Double(frame)*0.04)
                rgb += [0.16,0.20,0.23].map { Float($0*gain) }
            } }
            return ExposureSample(time: Double(frame)/10,level: 0,segment: 0,
                thumbnail: SpatialThumbnail(width: w,height: h,rgb: rgb))
        }
        let fields = samples.map { sample -> SpatialField in
            var field = SpatialField()
            field.surface = .init(width: w,height: h,channelEV: Array(repeating: 0,count: w*h*3),guide: sample.thumbnail!.rgb)
            return field
        }
        let output = TrackedSurfaceResidual.apply(samples: samples,stops: Array(repeating: 0,count: samples.count),fields: fields,options: SceneSettings())
        for frame in output { XCTAssertLessThan(frame.surface!.channelEV.map { abs($0) }.max()!,1e-5) }
    }

    func testRapidResidualRetainsCalibrationAndSlowRampButRemovesPulse() {
        let times = (0..<31).map { Double($0)/10 }
        let ramp = times.map { 0.15+0.08*$0 }
        let quiet = TrackedSurfaceResidual.rapidResidual(times: times,required: ramp,radius: 0.5,mode: .smooth)
        XCTAssertLessThan(quiet.map(abs).max()!,1e-8)
        let constant = TrackedSurfaceResidual.rapidResidual(times: times,required: Array(repeating: 0.15,count: times.count),radius: 0.5,mode: .steady)
        XCTAssertEqual(constant,Array(repeating: 0,count: times.count))
        var pulse = ramp; pulse[15] += 0.2
        let rapid = TrackedSurfaceResidual.rapidResidual(times: times,required: pulse,radius: 0.5,mode: .smooth)
        XCTAssertGreaterThan(rapid[15],0.18)
        XCTAssertLessThan(abs(rapid[0]),0.01)
        XCTAssertLessThan(abs(rapid[30]),0.01)
    }

    func testAutomaticIntervalCorrectsStationaryPulseAndRespectsPartialTarget() {
        let w = 96, h = 56, pulse = 5
        let samples: [ExposureSample] = (0..<11).map { frame in
            var rgb = [Float]()
            for y in 0..<h { for x in 0..<w {
                let texture = 0.22*sin(Double(x)*0.9)*cos(Double(y)*0.7)+0.06*cos(Double(x)*1.7+Double(y)*0.4)
                let gain = exp2(texture+(frame == pulse ? 0.4 : 0))
                rgb += [0.16,0.20,0.23].map { Float($0*gain) }
            } }
            return ExposureSample(time: Double(frame)/10,level: 0,segment: 0,
                thumbnail: SpatialThumbnail(width: w,height: h,rgb: rgb))
        }
        var fields = samples.map { sample -> SpatialField in
            var field = SpatialField()
            field.surface = .init(width: w,height: h,channelEV: Array(repeating: 0,count: w*h*3),guide: sample.thumbnail!.rgb)
            return field
        }
        let stops = Array(repeating: 0.0,count: samples.count)
        let result = PersistentLocalFlash.apply(samples: samples,stops: stops,fields: fields,options: SceneSettings())
        XCTAssertLessThan(result[pulse].surface!.channelEV.map(Double.init).reduce(0,+)/Double(w*h*3),-0.02)
        XCTAssertTrue(result.flatMap { $0.surface!.channelEV }.allSatisfy { abs($0) <= 0.250001 })
        let scoped = TrackedSurfaceResidual.apply(samples: samples,stops: stops,fields: fields,options: SceneSettings())
        XCTAssertLessThan(scoped[pulse].surface!.channelEV.map(Double.init).reduce(0,+)/Double(w*h*3),-0.02)
        XCTAssertTrue(scoped.flatMap { $0.surface!.channelEV }.allSatisfy { abs($0) <= 0.250001 })
        // Ideal half-strength output retains half the source flash. It must not
        // be corrected again toward the full-strength target.
        fields[pulse].surface = .init(width: w,height: h,channelEV: Array(repeating: -0.2,count: w*h*3),guide: samples[pulse].thumbnail!.rgb)
        let partial = PersistentLocalFlash.apply(samples: samples,stops: stops,fields: fields,options: SceneSettings(strength: 0.5))
        for i in fields.indices { XCTAssertEqual(partial[i].surface!.channelEV,fields[i].surface!.channelEV) }
        let scopedPartial = TrackedSurfaceResidual.apply(samples: samples,stops: stops,fields: fields,options: SceneSettings(strength: 0.5))
        for i in fields.indices {
            for (actual,expected) in zip(scopedPartial[i].surface!.channelEV,fields[i].surface!.channelEV) {
                XCTAssertEqual(actual,expected,accuracy: 1e-6)
            }
        }
        let scopedSpatial = TrackedSurfaceResidual.apply(samples: samples,stops: stops,fields: fields,options: SceneSettings(spatialStrength: 0.5))
        for i in fields.indices {
            for (actual,expected) in zip(scopedSpatial[i].surface!.channelEV,fields[i].surface!.channelEV) {
                XCTAssertEqual(actual,expected,accuracy: 1e-6)
            }
        }
        // A correct partial result may carry a deliberate constant calibration
        // offset and a slow drift. Neither belongs to the rapid residual layer.
        var calibrated = fields
        for i in calibrated.indices {
            let map = fields[i].surface!
            let offset = Float(0.15+0.04*samples[i].time)
            calibrated[i].surface = .init(width: w,height: h,channelEV: map.channelEV.map { $0+offset },guide: map.guide)
        }
        for settings in [SceneSettings(strength: 0.5),SceneSettings(spatialStrength: 0.5)] {
            let preserved = TrackedSurfaceResidual.apply(samples: samples,stops: stops,fields: calibrated,options: settings)
            for i in calibrated.indices {
                for (actual,expected) in zip(preserved[i].surface!.channelEV,calibrated[i].surface!.channelEV) {
                    XCTAssertEqual(actual,expected,accuracy: 1e-6)
                }
            }
        }
        let scopedDisabled = TrackedSurfaceResidual.apply(samples: samples,stops: stops,fields: fields,options: SceneSettings(spatialStrength: 0))
        for i in fields.indices { XCTAssertEqual(scopedDisabled[i].surface!.channelEV,fields[i].surface!.channelEV) }
        let disabled = PersistentLocalFlash.apply(samples: samples,stops: stops,fields: fields,options: SceneSettings(spatialStrength: 0))
        for i in fields.indices { XCTAssertEqual(disabled[i].surface!.channelEV,fields[i].surface!.channelEV) }
    }
}
