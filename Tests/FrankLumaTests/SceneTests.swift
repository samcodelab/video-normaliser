import XCTest
@testable import FrankLuma

final class SceneTests: XCTestCase {
    func testExposureFlashIsNotACut() {
        let light = (0..<100).map { 0.06 + Double($0) * 0.003 }
        let original = FrameAppearance(luminance: light, chromaticity: [0.2, 0.5, 0.3])
        let flash = FrameAppearance(luminance: light.map { $0 * 2 }, chromaticity: [0.2, 0.5, 0.3])
        XCTAssertFalse(SceneDetection.isCut(previous: original, current: flash))
    }

    func testColourCutWithSameBrightnessIsDetected() {
        let light = Array(repeating: 0.25, count: 100)
        let first = FrameAppearance(luminance: light, chromaticity: [1, 0, 0])
        let second = FrameAppearance(luminance: light, chromaticity: [0, 0, 1])
        XCTAssertTrue(SceneDetection.isCut(previous: first, current: second))
    }

    func testStructuralCutWithoutColourChangeIsDetected() {
        let light = Array(repeating: 0.1, count: 50) + Array(repeating: 0.6, count: 50)
        let first = FrameAppearance(luminance: light, chromaticity: [1])
        let second = FrameAppearance(luminance: light.reversed(), chromaticity: [1])
        XCTAssertTrue(SceneDetection.isCut(previous: first, current: second))
    }

    func testMovingForegroundIsNotACut() {
        let light = Array(repeating: 0.2, count: 100)
        let moved = Array(repeating: 0.2, count: 75) + Array(repeating: 0.65, count: 25)
        XCTAssertFalse(SceneDetection.isCut(previous: FrameAppearance(luminance: light, chromaticity: [0.8, 0.2]),
                                            current: FrameAppearance(luminance: moved, chromaticity: [0.7, 0.3])))
    }

    func testBothModesKeepSceneBaselinesIndependent() {
        let first = (0..<24).map { ExposureSample(time: Double($0) / 24, level: $0.isMultiple(of: 2) ? 0.2 : -0.2, segment: 0) }
        let second = (24..<48).map { ExposureSample(time: Double($0) / 24, level: $0.isMultiple(of: 2) ? 4.3 : 3.7, segment: 1) }
        for mode in NormalisationMode.allCases {
            let alone = ExposureMath.curve(samples: first, radius: 3, strength: 1, mode: mode)
            let together = ExposureMath.curve(samples: first + second, radius: 3, strength: 1, mode: mode)
            XCTAssertEqual(Array(together.stops.prefix(24)), alone.stops)
            XCTAssertLessThan(together.peak, 0.31)
            if mode == .steady {
                for i in 24..<48 { XCTAssertEqual((first + second)[i].level + together.stops[i], 4, accuracy: 0.00001) }
            }
        }
    }

    func testManualSplitAndMergeRebuildSceneWindows() {
        let raw = (0..<48).map { ExposureSample(time: Double($0) / 24, level: $0 < 24 ? 0 : 1, segment: 0) }
        let split = SceneMath.assign(raw, boundaries: [24])
        XCTAssertEqual(SceneMath.boundaries(in: split), [24])
        XCTAssertEqual(ExposureMath.curve(samples: split, radius: 3, strength: 1, mode: .steady).peak, 0)
        let scenes = SceneMath.scenes(samples: raw, boundaries: [24], duration: 2)
        XCTAssertEqual(scenes.count, 2)
        XCTAssertEqual(scenes[0].frameCount, 24)
        XCTAssertEqual(scenes[0].end, scenes[1].start)
        XCTAssertEqual(scenes[1].end, 2)
        let merged = SceneMath.assign(split, boundaries: [])
        XCTAssertEqual(ExposureMath.curve(samples: merged, radius: 3, strength: 1, mode: .steady).peak, 0.5)
    }

    func testColourDescriptorIgnoresUniformExposureChange() {
        let pixels: [UInt8] = (0..<64).flatMap { _ in [UInt8(50), 80, 100, 255] }
        let brighter: [UInt8] = (0..<64).flatMap { _ in [UInt8(100), 160, 200, 255] }
        let first = FrameAppearance(pixels: pixels, width: 8, height: 8)
        let second = FrameAppearance(pixels: brighter, width: 8, height: 8)
        XCTAssertEqual(first.chromaticity, second.chromaticity)
        XCTAssertFalse(SceneDetection.isCut(previous: first, current: second))
    }
}
