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
    func testUniformFlickerLeavesNoSpatialResidualAfterGlobalCorrection() {
        let frames=(0..<7).map { i in thumbnail(exposure: { _,_ in i == 3 ? -0.4 : 0 }) }
        let samples=frames.enumerated().map { ExposureSample(time:Double($0.offset)/12,level:0,segment:0,thumbnail:$0.element) }
        let fields=SpatialLighting.estimate(samples:samples,global:[0,0,0,0.4,0,0,0],radius:0.5,strength:1)
        XCTAssertLessThan(fields.map(\.peak).max()!,0.005)
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
