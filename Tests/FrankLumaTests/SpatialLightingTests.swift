import XCTest
@testable import FrankLuma

final class SpatialLightingTests: XCTestCase {
    private func thumbnail(exposure: (Double, Double) -> Double = { _,_ in 0 }, subjectX: Int? = nil, shift: Int = 0) -> SpatialThumbnail {
        let w=64,h=40
        var rgb=[Float]()
        for y in 0..<h { for x in 0..<w {
            let xx=x-shift
            let texture=0.28 + 0.035*sin(Double(xx)*0.6) + 0.025*cos(Double(y)*0.8)
            let gain=pow(2,exposure(Double(x)/Double(w-1),Double(y)/Double(h-1)))
            if let sx=subjectX, x>=sx && x<sx+10 && y>=15 && y<30 {
                rgb += [Float(0.6*gain),Float(0.15*gain),Float(0.06*gain)]
            } else { rgb += [Float(texture*gain),Float(texture*gain),Float(texture*gain)] }
        } }
        return SpatialThumbnail(width:w,height:h,rgb:rgb)
    }
    func testNeighbourSearchIsBoundedAndStaysInsideSceneAndRadius() {
        let samples = (0..<240).map { ExposureSample(time: Double($0)/12, level: 0, segment: $0 < 120 ? 0 : 1) }
        for index in samples.indices {
            for radius in [0.1, 0.5, 3.0] {
                let neighbours = SpatialLighting.neighbourIndices(samples: samples, index: index, radius: radius)
                let expected = samples.indices.filter {
                    $0 != index && samples[$0].segment == samples[index].segment
                    && abs(samples[$0].time - samples[index].time) <= max(0.25, radius) + 0.000001
                }.sorted {
                    let left = abs($0-index), right = abs($1-index)
                    return left == right ? $0 < $1 : left < right
                }
                XCTAssertEqual(neighbours, Array(expected.prefix(6)))
            }
        }
        XCTAssertTrue(SpatialLighting.estimate(samples: [], global: [], radius: 0.5, strength: 1).isEmpty)
    }

    func testCachedAlignmentMatchesFreshCalculationAfterRadiusAndModeChange() {
        let samples = (0..<9).map { i in
            ExposureSample(time: Double(i)/12, level: 0, segment: 0,
                           thumbnail: thumbnail(exposure: { _, y in i == 4 ? -0.3*y : 0 }, shift: i-4))
        }
        let first = SpatialLighting.estimate(samples: samples, global: Array(repeating: 0, count: 9), radius: 0.1, strength: 1)
        let global = (0..<9).map { $0 == 4 ? 0.1 : 0.0 }
        let reused = SpatialLighting.estimate(samples: samples, global: global, radius: 1, strength: 0.7, previous: first)
        let fresh = SpatialLighting.estimate(samples: samples, global: global, radius: 1, strength: 0.7)
        for i in samples.indices {
            XCTAssertEqual(reused[i].stops, fresh[i].stops)
            XCTAssertEqual(reused[i].offsets, fresh[i].offsets)
            XCTAssertEqual(reused[i].fallback, fresh[i].fallback)
            XCTAssertEqual(reused[i].alignments.map(\.reference), fresh[i].alignments.map(\.reference))
        }
    }

    func testParallelRangesMatchSerialWithCachedReferencesAcrossChunkEdges() async {
        let samples = (0..<12).map { i in ExposureSample(time: Double(i)/12, level: 0, segment: 0,
            thumbnail: thumbnail(exposure: { _, y in i == 6 ? -0.3*y : 0 }, shift: i-6)) }
        let global = Array(repeating: 0.0, count: 12)
        let serial = SpatialLighting.estimate(samples: samples, global: global, radius: 1, strength: 1)
        let parallel = await SpatialLighting.estimateAsync(samples: samples, global: global, radius: 1, strength: 1, chunkSize: 3)
        let cached = await SpatialLighting.estimateAsync(samples: samples, global: global, radius: 1, strength: 1, previous: serial, chunkSize: 3)
        for fields in [parallel, cached] {
            XCTAssertEqual(fields.count, serial.count)
            for i in serial.indices {
                XCTAssertEqual(fields[i].stops, serial[i].stops)
                XCTAssertEqual(fields[i].offsets, serial[i].offsets)
                XCTAssertEqual(fields[i].alignments.map(\.reference), serial[i].alignments.map(\.reference))
            }
        }
    }

    func testUnevenFlashesDoNotBorrowAnOvercorrectedFloorAsReference() {
        let w = 64, h = 40
        let frames = (0..<11).map { frame -> SpatialThumbnail in
            var rgb: [Float] = []
            for y in 0..<h { for x in 0..<w {
                let upper = y < h/2
                let light: Double = frame == 4 ? (upper ? -0.45 : -0.18) : frame == 5 ? (upper ? 0.10 : 0.28) : 0
                let texture = 0.9 + 0.1*sin(Double(x)*0.6)*cos(Double(y)*0.8)
                let colour = upper ? [0.015, 0.10, 0.40] : [0.07, 0.42, 0.12]
                rgb += colour.map { Float($0*texture*pow(2,light)) }
            } }
            return SpatialThumbnail(width: w, height: h, rgb: rgb)
        }
        let samples = frames.enumerated().map { ExposureSample(time: Double($0.offset)/12, level: 0, segment: 0, thumbnail: $0.element) }
        let global = (0..<11).map { $0 == 4 ? 0.45 : $0 == 5 ? -0.10 : 0.0 }
        for mode in NormalisationMode.allCases {
            for strength in [0.5, 1.0] {
                let fields = SpatialLighting.estimate(samples: samples, global: global, radius: 0.5, strength: strength, mode: mode)
                for frame in 3...6 {
                    XCTAssertNil(fields[frame].fallback)
                    for (y, light) in [(0.2, frame == 4 ? -0.45 : frame == 5 ? 0.10 : 0.0),
                                       (0.8, frame == 4 ? -0.18 : frame == 5 ? 0.28 : 0.0)] {
                        let ev = SpatialField.basis(x: 0.5, y: y, columns: 9, rows: 6).reduce(0) {
                            $0 + fields[frame].exposureStops[$1.0]*$1.1
                        }
                        let after = light + global[frame]*strength + ev
                        XCTAssertEqual(after, light*(1-strength), accuracy: 0.035,
                                       "Both saturated surfaces must follow their own target, including the frame after a flash")
                    }
                }
            }
        }
    }

    func testUniformFlickerLeavesNoSpatialResidualAfterGlobalCorrection() {
        let frames=(0..<7).map { i in thumbnail(exposure: { _,_ in i == 3 ? -0.4 : 0 }) }
        let samples=frames.enumerated().map { ExposureSample(time:Double($0.offset)/12,level:0,segment:0,thumbnail:$0.element) }
        let fields=SpatialLighting.estimate(samples:samples,global:[0,0,0,0.4,0,0,0],radius:0.5,strength:1)
        XCTAssertLessThan(fields.map(\.peak).max()!,0.005)
    }

    func testTexturedDarkSubjectReceivesItsOwnFlashCorrectionBesideMotion() {
        let w = 96, h = 56
        let frames = (0..<11).map { frame -> SpatialThumbnail in
            var rgb: [Float] = []
            for y in 0..<h { for x in 0..<w {
                let texture = 0.7 + 0.3*sin(Double(x)*0.8)*cos(Double(y)*0.9)
                let backgroundEV = frame == 4 ? -0.3 : frame == 5 ? 0.15 : 0
                if x >= 32, x < 64, y >= 10, y < 46 {
                    // Dark printed recesses reduce the usable pixel count.
                    // The flash changes contrast as well as average exposure.
                    let ink = (x+y) % 3 == 0 ? 0.12 : 1.0
                    let gain = frame == 4 ? 0.65 : frame == 5 ? 1.65 : 1.0
                    rgb += [0.32, 0.055, 0.025].map { Float($0*texture*ink*gain) }
                } else if x >= frame*2, x < frame*2+8, y >= 20, y < 38 {
                    rgb += [0.1, 0.35, 0.05].map { Float($0*pow(2,backgroundEV)) }
                } else {
                    rgb += [0.025, 0.12, 0.4].map { Float($0*texture*pow(2,backgroundEV)) }
                }
            } }
            return SpatialThumbnail(width: w, height: h, rgb: rgb)
        }
        let samples = frames.enumerated().map {
            ExposureSample(time: Double($0.offset)/12, level: 0, segment: 0, thumbnail: $0.element)
        }
        let global = (0..<11).map { $0 == 4 ? 0.3 : $0 == 5 ? -0.15 : 0.0 }
        for mode in NormalisationMode.allCases {
            let fields = SpatialLighting.estimate(samples: samples, global: global, radius: 0.5, strength: 1, mode: mode)
            for frame in 4...5 {
                XCTAssertNil(fields[frame].fallback)
                let residual = SpatialField.basis(x: 0.5, y: 0.5, columns: 9, rows: 6).reduce(0) {
                    $0 + fields[frame].exposureStops[$1.0]*$1.1
                }
                let error = log2(frame == 4 ? 0.65 : 1.65)+global[frame]+residual
                XCTAssertLessThan(abs(error), 0.10, "A subject flash must not be discarded as motion or a spatial outlier")
            }
        }
    }
    func testSpatialFlashStabilisesUpperAndLowerBackgroundWithoutTemporalBleed() {
        let frames=(0..<7).map { i in thumbnail(exposure: { _,y in i == 3 ? -0.5*y : 0 }) }
        let samples=frames.enumerated().map { ExposureSample(time:Double($0.offset)/12,level:0,segment:0,thumbnail:$0.element) }
        let fields=SpatialLighting.estimate(samples:samples,global:[0,0,0,0.2,0,0,0],radius:0.5,strength:1)
        XCTAssertNil(fields[3].fallback)
        for y in [0.15,0.5,0.85] {
            let residual = -0.5*y + 0.2 + fields[3].value(x:0.3,y:y)
            XCTAssertLessThan(abs(pow(2,residual)-1),0.02)
        }
        XCTAssertLessThan(fields[2].peak,0.03)
        XCTAssertLessThan(fields[4].peak,0.03)
    }
    func testMovingSubjectUnderConstantLightDoesNotDriveTheField() {
        let frames=(0..<7).map { thumbnail(subjectX:8+$0*5) }
        let samples=frames.enumerated().map { ExposureSample(time:Double($0.offset)/12,level:0,segment:0,thumbnail:$0.element) }
        let fields=SpatialLighting.estimate(samples:samples,global:Array(repeating:0,count:7),radius:0.5,strength:1)
        XCTAssertLessThan(fields.map(\.peak).max()!,0.02)
        XCTAssertTrue(fields.contains { $0.motion.contains { $0 > 0.5 } })
    }
    func testReferencesNeverCrossACameraCut() {
        let samples=(0..<8).map { i in ExposureSample(time:Double(i)/12,level:0,segment:i<4 ? 0:1,
                                                      thumbnail:thumbnail(exposure:{ _,_ in i<4 ? 0:1 })) }
        let fields=SpatialLighting.estimate(samples:samples,global:Array(repeating:0,count:8),radius:3,strength:1)
        XCTAssertLessThan(fields.map(\.peak).max()!,0.005)
        for i in fields.indices { XCTAssertTrue(fields[i].alignments.allSatisfy { samples[$0.reference].segment == samples[i].segment }) }
    }
    func testTranslationRegistrationDoesNotTreatCameraMotionAsExposure() {
        let samples=(0..<7).map { i in ExposureSample(time:Double(i)/12,level:0,segment:0,thumbnail:thumbnail(shift:i-3)) }
        let fields=SpatialLighting.estimate(samples:samples,global:Array(repeating:0,count:7),radius:0.5,strength:1)
        XCTAssertLessThan(fields.map(\.peak).max()!,0.03)
        XCTAssertTrue(fields[3].alignments.contains { $0.accepted && $0.dx != 0 })
    }

    func testTexturedBackgroundUsesMatchedEnergyWithoutCreatingBrightPulse() {
        // Most pixels are dark recesses, but the brighter studs contribute
        // most of the patch's energy. A median ratio overweights recesses.
        let w = 96, h = 56
        let frames = (0..<7).map { frame -> SpatialThumbnail in
            var rgb: [Float] = []
            for y in 0..<h { for x in 0..<w {
                let bright = (x + y) % 3 == 0
                let level = bright ? 0.65 : 0.16
                let gain = frame == 3 ? (bright ? 0.735 : 0.7) : 1.0
                rgb += Array(repeating: Float(level * gain), count: 3)
            } }
            return SpatialThumbnail(width: w, height: h, rgb: rgb)
        }
        let samples = frames.enumerated().map {
            ExposureSample(time: Double($0.offset)/12, level: 0, segment: 0, thumbnail: $0.element)
        }
        let global = [0.0, 0, 0, 0.4, 0, 0, 0]
        let fields = SpatialLighting.estimate(samples: samples, global: global, radius: 0.5, strength: 1)
        XCTAssertNil(fields[3].fallback)
        var before = 0.0, after = 0.0, target = 0.0
        for y in 4..<(h-4) { for x in 4..<(w-4) {
            let index = (y*w+x)*3
            let light = Double(frames[3].rgb[index])
            before += light * pow(2, global[3])
            after += light * pow(2, global[3] + fields[3].value(x: Double(x)/Double(w-1), y: Double(y)/Double(h-1))) + fields[3].offset(x: Double(x)/Double(w-1), y: Double(y)/Double(h-1))
            target += Double(frames[2].rgb[index])
        } }
        XCTAssertLessThan(abs(after/target-1), 0.006)
        XCTAssertLessThan(abs(after-target), abs(before-target))
        XCTAssertLessThan(fields[2].peak, 0.01)
        XCTAssertLessThan(fields[4].peak, 0.01)
    }

    func testDiffuseLightingChangeMatchesBothDarkAndBrightTexture() {
        let w=96, h=56
        let frames=(0..<7).map { frame -> SpatialThumbnail in
            var rgb: [Float]=[]
            for y in 0..<h { for x in 0..<w {
                let target = (x+y)%3 == 0 ? 0.65 : 0.30
                let value = frame == 3 ? (target-0.15)/1.05 : target
                rgb += Array(repeating:Float(value),count:3)
            } }
            return SpatialThumbnail(width:w,height:h,rgb:rgb)
        }
        let samples=frames.enumerated().map { ExposureSample(time:Double($0.offset)/12,level:0,segment:0,thumbnail:$0.element) }
        let global=[0.0,0,0,0.4,0,0,0]
        let fields=SpatialLighting.estimate(samples:samples,global:global,radius:0.5,strength:1)
        XCTAssertNil(fields[3].fallback)
        for target in [0.30,0.65] {
            let source=(target-0.15)/1.05
            let output=source*pow(2,global[3]+fields[3].value(x:0.5,y:0.5))+fields[3].offset(x:0.5,y:0.5)
            XCTAssertEqual(output,target,accuracy:0.012)
        }
        for i in [2,4] {
            XCTAssertLessThan(fields[i].peak,0.02)
            XCTAssertLessThan(fields[i].offsets.map(abs).max()!,0.005)
        }
    }

    func testManualMergeOverridesFalseAutomaticCutForSpatialReferences() {
        let samples=(0..<8).map { i in ExposureSample(time:Double(i)/12,level:0,segment:i<4 ? 0:1,
                                                      thumbnail:thumbnail()) }
        let merged=SceneCorrection.curve(base:samples,boundaries:[],settings:[:],references:[:])
        XCTAssertTrue(merged.spatial[3].alignments.contains { $0.accepted && $0.reference >= 4 })
        let split=SceneCorrection.curve(base:samples,boundaries:[4],settings:[:],references:[:])
        XCTAssertTrue(split.spatial[3].alignments.allSatisfy { $0.reference < 4 })
    }
}
