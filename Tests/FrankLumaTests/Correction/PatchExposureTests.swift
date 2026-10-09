import XCTest
@testable import FrankLuma

final class PatchExposureTests: XCTestCase {
    func testStationaryBackgroundProofSeparatesExposureFromMovingTexture() {
        let cells = Array(repeating: Array(repeating: 0.2,count: 336),count: 20)
        let patches = PatchExposure(cells: cells)
        func image(frame: Int,moving: Bool) -> SpatialThumbnail {
            let rgb = (0..<(96*56)).flatMap { p -> [Float] in
                let x = p%96+(moving ? frame : 0),y = p/96
                let texture = 0.08+Double((x*17+y*31+x*y*7)%53)/53*0.18
                return Array(repeating: Float(texture*pow(2,frame.isMultiple(of: 2) ? 0.2 : -0.2)),count: 3)
            }
            return SpatialThumbnail(width: 96,height: 56,rgb: rgb)
        }
        XCTAssertTrue(patches.hasStationaryBackground(thumbnails: (0..<20).map { image(frame: $0,moving: false) }))
        XCTAssertFalse(patches.hasStationaryBackground(thumbnails: (0..<20).map { image(frame: $0,moving: true) }))
        XCTAssertFalse(patches.hasStationaryBackground(thumbnails: Array(repeating: nil,count: 20)))
        let reference = image(frame: 0,moving: false)
        let contrastChanged = SpatialThumbnail(width: 96,height: 56,rgb: reference.rgb.map { Float(pow(Double($0),2)) })
        XCTAssertLessThan(SurfaceTracking.stationaryConfidence(contrastChanged,reference,x: 40,y: 24),0.3)
        XCTAssertGreaterThan(SurfaceTracking.stationaryShapeConfidence(contrastChanged,reference,x: 40,y: 24),0.99)
        XCTAssertLessThan(SurfaceTracking.stationaryShapeConfidence(image(frame: 4,moving: true),reference,x: 40,y: 24),0.5)
    }

    func testSmoothPatchTargetsRetainLocalRampAndSuppressRapidFlicker() throws {
        let times = (0..<120).map { Double($0)/10 }
        let cells = times.indices.map { frame in (0..<336).map { patch in
            patch%24 < 6 ? 0.2*pow(2,Double(frame)/119*0.12+(frame.isMultiple(of: 2) ? 0.08 : -0.08)) : 0.2
        } }
        let patches = PatchExposure(cells: cells)
        let global = Array(repeating: 0.0,count: times.count)
        let targets = patches.smoothBrightnessTargets(cells: cells,times: times,radius: 0.5,strength: 1,global: global,spatialStrength: 1)
        let levels = try targets.map { try XCTUnwrap($0[3]) }
        XCTAssertGreaterThan(levels[110]-levels[10],0.08)
        XCTAssertLessThan(zip(levels,levels.dropFirst()).map { abs($0-$1) }.max()!,0.03)
        let half = patches.smoothBrightnessTargets(cells: cells,times: times,radius: 0.5,strength: 1,global: global,spatialStrength: 0.5)
        let off = patches.smoothBrightnessTargets(cells: cells,times: times,radius: 0.5,strength: 0,global: global,spatialStrength: 1)
        for i in times.indices {
            let source = log2(cells[i][3])
            XCTAssertEqual(try XCTUnwrap(half[i][3]),(source+levels[i])/2,accuracy: 0.000001)
            XCTAssertEqual(try XCTUnwrap(off[i][3]),source,accuracy: 0.000001)
        }
    }

    func testRegionalBrightnessExposesFlashHiddenBySceneMedian() throws {
        let source = Array(repeating: Array(repeating: 0.2,count: 336),count: 20)
        let patches = PatchExposure(cells: source)
        var rendered = source[0]
        for p in rendered.indices where p%24 < 6 && p/24 < 5 { rendered[p] = 0.4 }
        XCTAssertEqual(try XCTUnwrap(patches.brightnessLevel(cells: rendered,frame: 0)),0,accuracy: 0.000001)
        let regions = patches.brightnessRegionLevels(cells: rendered,frame: 0)
        XCTAssertEqual(try XCTUnwrap(regions[0]),1,accuracy: 0.000001)
        for value in regions.dropFirst() { XCTAssertEqual(try XCTUnwrap(value),0,accuracy: 0.000001) }
        XCTAssertTrue(patches.brightnessRegionLevels(cells: [],frame: 0).allSatisfy { $0 == nil })
    }

    func testBriefOcclusionsInvalidateObservationsWithoutDiscardingBackgroundTracks() {
        let count = 42
        let lighting = (0..<count).map { 0.3 * sin(Double($0) * 0.63) }
        let cells = (0..<count).map { frame in (0..<336).map { patch in
            patch / 24 == frame % 14 ? 1.0 : 0.23 * pow(2, lighting[frame])
        } }
        let thumbnails = (0..<count).map { frame -> SpatialThumbnail? in
            var rgb: [Float] = []
            for y in 0..<56 { for _ in 0..<96 {
                let colour = y / 4 == frame % 14 ? [1.0, 1.0, 1.0] : [0.18, 0.30, 0.12].map { $0 * pow(2, lighting[frame]) }
                rgb += colour.map(Float.init)
            } }
            return SpatialThumbnail(width: 96, height: 56, rgb: rgb)
        }
        XCTAssertFalse(PatchExposure(cells: cells).reliable, "Every fixed position is briefly clipped")
        let tracked = PatchExposure(cells: cells, thumbnails: thumbnails)
        XCTAssertTrue(tracked.reliable)
        let curve = tracked.curve(times: (0..<count).map { Double($0) / 12 }, radius: 0.5, strength: 1, mode: .steady)
        let after = zip(lighting, curve.stops).map(+)
        let centre = ExposureMath.median(after)
        XCTAssertLessThan(sqrt(after.map { pow($0-centre,2) }.reduce(0,+) / Double(count)), 0.035)
        XCTAssertLessThan(curve.peak, 0.4)
    }

    func testTwoFrameShotStillCorrectsExposure() {
        let cells = [Array(repeating: 0.20, count: 336), Array(repeating: 0.24, count: 336)]
        let thumbnails = [SpatialThumbnail(width: 24, height: 14, rgb: Array(repeating: 0.20, count: 1008)),
                          SpatialThumbnail(width: 24, height: 14, rgb: Array(repeating: 0.24, count: 1008))]
        let measure = PatchExposure(cells: cells, thumbnails: thumbnails)
        for mode in [NormalisationMode.smooth, .steady] {
            let curve = measure.curve(times: [0, 0.1], radius: 0.5, strength: 1, mode: mode)
            XCTAssertGreaterThan(curve.stops[0], 0.10)
            XCTAssertLessThan(curve.stops[1], -0.10)
            XCTAssertEqual(log2(0.20) + curve.stops[0], log2(0.24) + curve.stops[1], accuracy: 0.000001)
        }
    }

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
