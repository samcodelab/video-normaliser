import XCTest
@testable import VideoNormaliser

final class TimelineTests: XCTestCase {
    func testComparisonShowsOriginalAndCorrectedOnSameSceneBaseline() {
        let samples = [9.5, 10.5, -3.2, -2.8].enumerated().map {
            ExposureSample(time: Double($0.offset), level: $0.element, segment: 0)
        }
        let settings = [0: SceneSettings(mode: .steady), 2: SceneSettings(mode: .steady)]
        let curve = SceneCorrection.curve(base: samples, boundaries: [2], settings: settings, references: [:])
        let comparison = SceneCorrection.exposure(base: samples, boundaries: [2], settings: settings, references: [:], curve: curve)
        XCTAssertEqual(comparison.original[0], -0.5, accuracy: 0.00001)
        XCTAssertEqual(comparison.original[2], -0.2, accuracy: 0.00001)
        for value in comparison.corrected { XCTAssertEqual(value, 0, accuracy: 0.00001) }
    }

    func testZeroStrengthComparisonOverlapsAndUsesReferenceMeasurement() {
        let base = [0.0, 0.0].enumerated().map { ExposureSample(time: Double($0.offset), level: $0.element, segment: 0) }
        let measured = [-0.3, 0.3].enumerated().map { ExposureSample(time: Double($0.offset), level: $0.element, segment: 0) }
        let region = ReferenceRegion(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        let settings = [0: SceneSettings(strength: 0, reference: region)]
        let curve = SceneCorrection.curve(base: base, boundaries: [], settings: settings, references: [region: measured])
        let comparison = SceneCorrection.exposure(base: base, boundaries: [], settings: settings, references: [region: measured], curve: curve)
        XCTAssertEqual(comparison.original, [-0.3, 0.3])
        XCTAssertEqual(comparison.corrected, comparison.original)
    }

    func testFrameLookupUsesActualVariableTimestamps() {
        let samples = [0.0, 0.04, 0.125, 0.3].map { ExposureSample(time: $0, level: 0, segment: 0) }
        XCTAssertEqual(TimelineMath.frame(at: 0.12, samples: samples), 1)
        XCTAssertEqual(TimelineMath.nearestFrame(at: 0.12, samples: samples), 2)
        XCTAssertEqual(TimelineMath.frame(at: -1, samples: samples), 0)
        XCTAssertEqual(TimelineMath.frame(at: 99, samples: samples), 3)
        XCTAssertEqual(TimelineMath.frame(at: 0.125 - 0.00000001, samples: samples), 2)
    }

    func testBoundariesCannotCrossOrCreateEmptyScenes() {
        let cuts: Set<Int> = [10, 20, 30]
        XCTAssertEqual(TimelineMath.clampedBoundary(0, moving: 20, boundaries: cuts, frameCount: 40), 11)
        XCTAssertEqual(TimelineMath.clampedBoundary(100, moving: 20, boundaries: cuts, frameCount: 40), 29)
        XCTAssertEqual(TimelineMath.clampedBoundary(-1, moving: 10, boundaries: cuts, frameCount: 40), 1)
        XCTAssertEqual(TimelineMath.clampedBoundary(99, moving: 30, boundaries: cuts, frameCount: 40), 39)
    }

    func testSettingsAffectOnlyTheirOwnScene() {
        let samples = (0..<48).map { ExposureSample(time: Double($0) / 24, level: $0.isMultiple(of: 2) ? 0.3 : -0.3, segment: 0) }
        let normal = SceneSettings(strength: 1, radius: 0.5, mode: .steady)
        let disabled = SceneSettings(strength: 0, radius: 3, mode: .smooth)
        let curve = SceneCorrection.curve(base: samples, boundaries: [24], settings: [0: normal, 24: disabled], references: [:])
        XCTAssertTrue(curve.stops.prefix(24).allSatisfy { abs(abs($0) - 0.3) < 0.00001 })
        XCTAssertTrue(curve.stops.suffix(24).allSatisfy { $0 == 0 })
        let changed = SceneCorrection.curve(base: samples, boundaries: [24], settings: [0: normal, 24: normal], references: [:])
        XCTAssertEqual(Array(curve.stops.prefix(24)), Array(changed.stops.prefix(24)))
    }

    func testReferenceAreaAffectsOnlySelectedSceneAndSurvivesBoundaryMove() {
        let base = (0..<48).map { ExposureSample(time: Double($0) / 24, level: 0, segment: 0) }
        let measured = (0..<48).map { ExposureSample(time: Double($0) / 24, level: $0.isMultiple(of: 2) ? 0.5 : -0.5, segment: 0) }
        let region = ReferenceRegion(CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        let options = SceneSettings(strength: 1, radius: 1, mode: .steady, reference: region)
        for boundary in [24, 30] {
            let curve = SceneCorrection.curve(base: base, boundaries: [boundary], settings: [boundary: options], references: [region: measured])
            XCTAssertTrue(curve.stops.prefix(boundary).allSatisfy { $0 == 0 })
            XCTAssertTrue(curve.stops.suffix(48 - boundary).allSatisfy { abs(abs($0) - 0.5) < 0.00001 })
        }
    }

    func testSmoothingRadiusAndModeAreIndependentAcrossScenes() {
        let samples = (0..<48).map { ExposureSample(time: Double($0) / 12, level: Double($0) * 0.02 + ($0.isMultiple(of: 2) ? 0.3 : -0.3), segment: 0) }
        let first = SceneSettings(strength: 0.5, radius: 0.1, mode: .smooth)
        let second = SceneSettings(strength: 1, radius: 3, mode: .steady)
        let combined = SceneCorrection.curve(base: samples, boundaries: [24], settings: [0: first, 24: second], references: [:])
        let expectedFirst = ExposureMath.curve(samples: Array(samples.prefix(24)), radius: 0.1, strength: 0.5)
        let expectedSecond = ExposureMath.curve(samples: Array(samples.suffix(24)), radius: 3, strength: 1, mode: .steady)
        XCTAssertEqual(combined.stops, expectedFirst.stops + expectedSecond.stops)
    }
}
