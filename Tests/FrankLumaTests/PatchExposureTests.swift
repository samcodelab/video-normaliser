import XCTest
@testable import FrankLuma

final class PatchExposureTests: XCTestCase {
    func testConstantLightingWithMovingSubjectsNeedsNoCorrection() {
        let cells = (0..<40).map { frame in (0..<120).map { patch in
            patch < 80 ? 0.2 + Double(patch) * 0.003 : (frame + patch).isMultiple(of: 3) ? 0.08 : 0.6
        } }
        let measure = PatchExposure(cells: cells)
        XCTAssertTrue(measure.reliable)
        let curve = measure.curve(times: (0..<40).map { Double($0) / 12 }, radius: 0.5, strength: 1, mode: .smooth)
        XCTAssertEqual(curve.peak, 0, accuracy: 0.000001)
    }

    func testIsolatedDipDoesNotDarkenItsNeighbours() {
        let samples = (0..<21).map { ExposureSample(time: Double($0) / 12, level: $0 == 10 ? -0.5 : 0, segment: 0) }
        let curve = ExposureMath.curve(samples: samples, radius: 0.5, strength: 1)
        XCTAssertEqual(curve.stops[10], 0.5, accuracy: 0.000001)
        for i in samples.indices where i != 10 { XCTAssertEqual(curve.stops[i], 0, accuracy: 0.000001) }
    }

    func testNonuniformFlashUsesConservativeGainInStops() {
        let cells = (0..<15).map { frame in (0..<120).map { patch in
            0.3 * pow(2, frame == 7 ? (patch < 70 ? -0.4 : -0.6) : 0)
        } }
        let measure = PatchExposure(cells: cells)
        let curve = measure.curve(times: (0..<15).map { Double($0) / 12 }, radius: 0.5, strength: 1, mode: .steady)
        XCTAssertEqual(curve.stops[7], 0.4, accuracy: 0.000001)
        XCTAssertEqual(cells[7][0] * pow(2, curve.stops[7]), 0.3, accuracy: 0.000001)
    }

    func testInsufficientUnclippedPatchesDoNotProduceCorrection() {
        let measure = PatchExposure(cells: Array(repeating: Array(repeating: 1, count: 336), count: 10))
        XCTAssertFalse(measure.reliable)
        XCTAssertEqual(measure.curve(times: (0..<10).map(Double.init), radius: 1, strength: 1, mode: .steady).peak, 0)
    }

    func testOpeningShotRetainsSmallCorrections() throws {
        let url = try XCTUnwrap(TestResources.bundle.url(forResource: "ScenePatches", withExtension: "json", subdirectory: "Fixtures"))
        let cells = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: url))
        let model = PatchExposure(cells: Array(cells[0..<11]))
        let log = model.diagnostics(times: (0..<11).map { Double($0) / 12 }, radius: 0.5, strength: 1, mode: .smooth)
        XCTAssertGreaterThan(log[9].appliedEV, 0.06, "The opening dark dip must not be suppressed by the conservative quantile")
        for frame in log {
            XCTAssertEqual(frame.requestedEV, frame.appliedEV, accuracy: 0.000001)
            XCTAssertNil(frame.rejectionReason)
        }
        // Static, neutral wall on the right of the opening shot.
        let wall = (2..<6).flatMap { row in (20..<23).map { row * 24 + $0 } }
        let before = cells.prefix(11).map { frame in wall.map { log2(frame[$0]) }.reduce(0, +) / Double(wall.count) }
        let after = zip(before, log).map { $0 + $1.appliedEV }
        func energy(_ values: [Double]) -> Double { zip(values, values.dropFirst()).map { pow($1 - $0, 2) }.reduce(0, +) }
        XCTAssertLessThan(energy(after), energy(before) * 0.15)
    }

    func testBroaderPatchValidationReducesFrame13Overshoot() throws {
        let url = try XCTUnwrap(TestResources.bundle.url(forResource: "ScenePatches", withExtension: "json", subdirectory: "Fixtures"))
        let cells = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: url))
        let model = PatchExposure(cells: Array(cells[11..<18]))
        let log = model.diagnostics(times: (11..<18).map { Double($0) / 12 }, radius: 0.5, strength: 1, mode: .smooth)
        XCTAssertLessThan(log[2].appliedEV, log[2].requestedEV)
        XCTAssertLessThan(log[2].appliedEV, 0.39)
        XCTAssertEqual(log[2].rejectionReason, "Broader patch check reduced overshoot")
    }

    func testReportedProblemFramesAgainstFixedWallPatches() throws {
        // Full-resolution linear-light tile averages, 24 columns × 14 rows.
        // These are measurements, not images. Frame numbers are zero-based.
        let url = try XCTUnwrap(TestResources.bundle.url(forResource: "ScenePatches", withExtension: "json", subdirectory: "Fixtures"))
        let cells = try JSONDecoder().decode([[Double]].self, from: Data(contentsOf: url))
        let wall = (1..<4).flatMap { row in (3..<21).map { row * 24 + $0 } }
        for (start, end, problem) in [(11, 18, 12..<15), (38, 50, 40..<45), (50, 86, 79..<86)] {
            let measure = PatchExposure(cells: Array(cells[start..<end]))
            XCTAssertTrue(measure.reliable)
            let curve = measure.curve(times: (start..<end).map { Double($0) / 12 }, radius: 0.5, strength: 1, mode: .smooth)
            let before = (start..<end).map { frame in wall.map { log2(cells[frame][$0]) }.reduce(0, +) / Double(wall.count) }
            let after = zip(before, curve.stops).map(+)
            func energy(_ values: [Double]) -> Double { zip(values, values.dropFirst()).map { pow($1 - $0, 2) }.reduce(0, +) }
            XCTAssertLessThan(energy(after), energy(before) * 0.5, "Scene beginning at frame \(start)")
            let baseline = ExposureMath.median(before)
            for frame in problem where before[frame - start] < baseline - 0.08 {
                XCTAssertLessThanOrEqual(after[frame - start], baseline + 0.02, "Dark outlier \(frame) must not become a bright pulse")
            }
        }
    }
}
