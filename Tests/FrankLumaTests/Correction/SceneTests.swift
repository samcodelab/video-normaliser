import XCTest
@testable import FrankLuma

final class SceneTests: XCTestCase {
    private func subjectFrame(colour: [UInt8], x: Int = 12, gain: Double = 1) -> FrameAppearance {
        var pixels: [UInt8] = []
        for row in 0..<32 { for column in 0..<48 {
            let rgb: [UInt8] = (8..<24).contains(row) && (x..<x+24).contains(column)
                ? colour : [30, 55, 180]
            pixels += rgb.map { UInt8(clamping: Int(Double($0) * gain)) } + [255]
        } }
        return FrameAppearance(pixels: pixels, width: 48, height: 32)
    }

    func testPersistentSubjectReplacementCutsDespiteIdenticalBackground() {
        let old = subjectFrame(colour: [160, 30, 20])
        let new = subjectFrame(colour: [25, 160, 35])
        XCTAssertFalse(SceneDetection.isCut(previous: old, current: new), "Whole-frame comparison misses this regional change")
        XCTAssertTrue(SceneDetection.isCut(preceding: old, previous: old, current: new, following: [new, new, new]))
    }

    func testRegionalDetectionKeepsMotionExposureAndTransientColourFlashesInShot() {
        let old = subjectFrame(colour: [160, 30, 20])
        let moved = subjectFrame(colour: [160, 30, 20], x: 22)
        let exposed = subjectFrame(colour: [160, 30, 20], gain: 1.25)
        let flash = subjectFrame(colour: [25, 160, 35])
        let changingLight = subjectFrame(colour: [160, 65, 20])
        XCTAssertFalse(SceneDetection.isCut(preceding: old, previous: old, current: moved, following: [moved, moved, moved]))
        XCTAssertFalse(SceneDetection.isCut(preceding: old, previous: old, current: exposed, following: [exposed, exposed, exposed]))
        XCTAssertFalse(SceneDetection.isCut(preceding: old, previous: old, current: flash, following: [old, old, old]))
        XCTAssertFalse(SceneDetection.isCut(preceding: old, previous: old, current: flash, following: [flash, flash, old]),
                       "A three-frame lighting flash must not become a new shot")
        XCTAssertFalse(SceneDetection.isCut(preceding: old, previous: flash, current: old, following: [old, old, old]))
        XCTAssertFalse(SceneDetection.isCut(preceding: changingLight, previous: old, current: flash, following: [flash, flash, flash]),
                       "Already changing regional colour is not evidence of a settled shot being replaced")
    }

    func testFoxSamePaletteCutsAndFlashes() throws {
        let url = try XCTUnwrap(TestResources.bundle.url(forResource: "fox-scene-appearances", withExtension: "json", subdirectory: "Fixtures"))
        let pixels = try JSONDecoder().decode([String: [UInt8]].self, from: Data(contentsOf: url))
        func frame(_ index: Int) -> FrameAppearance {
            FrameAppearance(pixels: pixels[String(index)]!, width: 48, height: 32)
        }
        for index in [200, 400, 349, 559] {
            let cut = SceneDetection.isCut(preceding: frame(index-2), previous: frame(index-1),
                current: frame(index), following: (1...3).map { frame(index+$0) })
            XCTAssertEqual(cut, index == 200 || index == 400, "Frame \(index)")
        }
    }

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

    func testContinuousLargeSubjectMotionDoesNotCreateRepeatedCuts() {
        let light = Array(repeating: 0.1, count: 50) + Array(repeating: 0.6, count: 50)
        let first = FrameAppearance(luminance: light, chromaticity: [0.7, 0.3])
        let moved = FrameAppearance(luminance: light.reversed(), chromaticity: [0.6, 0.4])
        XCTAssertTrue(SceneDetection.isCut(preceding: first, previous: first, current: moved),
                      "A structural cut from a stable shot must still be detected")
        XCTAssertFalse(SceneDetection.isCut(preceding: first, previous: moved, current: first, following: [moved, first]),
                       "Continuing subject motion must not fragment a shot")
        XCTAssertTrue(SceneDetection.isCut(preceding: first, previous: moved, current: first, following: [first, first]),
                      "A stable new shot must still cut after subject motion")
        XCTAssertTrue(SceneDetection.isCut(preceding: first, previous: moved, current: first, following: [moved, moved]),
                      "A new shot that settles after an initial movement must still cut")
        let differentScene = FrameAppearance(luminance: light, chromaticity: [0, 1])
        XCTAssertTrue(SceneDetection.isCut(preceding: first, previous: moved, current: differentScene),
                      "A different-colour scene must still cut during motion")
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

    func testReanalysisRefreshesAutomaticCutsButPreservesReviewedCutsAndSettings() {
        let frames = (0..<8).map { ExposureSample(time: Double($0)/12, level: 0, segment: 0) }
        let old = SceneMath.assign(frames, boundaries: [4])
        let newlyDetected = SceneMath.assign(frames, boundaries: [2, 4])
        let first = SceneSettings(strength: 0.3, mode: .steady)
        let second = SceneSettings(strength: 0.8)
        let automatic = SceneMath.refreshedCuts(previous: old, current: newlyDetected, boundaries: [4],
            settings: [0: first, 4: second], defaults: SceneSettings())
        XCTAssertEqual(automatic.boundaries, [2, 4])
        XCTAssertEqual(automatic.settings, [0: first, 2: first, 4: second])
        let manual = SceneMath.refreshedCuts(previous: old, current: newlyDetected, boundaries: [3],
            settings: [0: first, 3: second], defaults: SceneSettings())
        XCTAssertEqual(manual.boundaries, [3])
        XCTAssertEqual(manual.settings, [0: first, 3: second])
        let differentFrames = newlyDetected.map { ExposureSample(time: $0.time + 0.01, level: 0, segment: $0.segment) }
        let changed = SceneMath.refreshedCuts(previous: old, current: differentFrames, boundaries: [3],
            settings: manual.settings, defaults: SceneSettings())
        XCTAssertFalse(changed.sameFrames)
        XCTAssertEqual(changed.boundaries, [2, 4])
        XCTAssertTrue(changed.settings.values.allSatisfy { $0 == SceneSettings() })
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
