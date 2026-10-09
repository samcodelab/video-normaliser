import XCTest
@testable import FrankLuma

final class SharedFlashAnchorTests: XCTestCase {
    func testUnsupportedTransitionsKeepTheirGainDifference() {
        let gains = SharedFlashAnchor.adjustments(count: 13, residuals: [8: -0.15], amount: 1)
        XCTAssertGreaterThan(gains[8]-gains[7], 0.05)
        for frame in 1..<13 where frame != 8 {
            XCTAssertEqual(gains[frame], gains[frame-1], accuracy: 1e-12)
        }
        XCTAssertEqual(ExposureMath.median(gains), 0, accuracy: 1e-12)
        XCTAssertTrue(gains.allSatisfy { abs($0) <= 0.25 })
        XCTAssertEqual(SharedFlashAnchor.adjustments(count: 13, residuals: [8: -0.15], amount: 0), Array(repeating: 0, count: 13))
        let half = SharedFlashAnchor.adjustments(count: 13, residuals: [8: -0.15], amount: 0.5)
        XCTAssertEqual(half[8]-half[7], (gains[8]-gains[7])*0.5, accuracy: 1e-12)
        XCTAssertEqual(SharedFlashAnchor.adjustments(count: 13, residuals: [8: -0.01], amount: 1), Array(repeating: 0, count: 13))
    }

    func testRegionalDisagreementRejectsSharedResidual() {
        let matching = (0..<16).map { i in
            SharedFlashAnchor.Observation(x: i < 8 ? 20 : 70, source: -0.3, rendered: -0.12)
        }
        XCTAssertEqual(SharedFlashAnchor.residual(matching, width: 96, trend: 0, amount: 1)!, -0.12, accuracy: 1e-12)
        let independent = (0..<16).map { i in
            SharedFlashAnchor.Observation(x: i < 8 ? 20 : 70, source: -0.3, rendered: i < 8 ? -0.12 : 0.12)
        }
        XCTAssertNil(SharedFlashAnchor.residual(independent, width: 96, trend: 0, amount: 1))
        XCTAssertNil(SharedFlashAnchor.residual(matching, width: 96, trend: -0.12, amount: 1))
        let alreadySmooth = matching.map {
            SharedFlashAnchor.Observation(x: $0.x, source: $0.source, rendered: 0.02)
        }
        XCTAssertNil(SharedFlashAnchor.residual(alreadySmooth, width: 96, trend: -0.15, amount: 1))
    }

    func testSmallIndependentMaterialCannotBeOutvotedByBackground() {
        let observations = (0..<24).map { i in
            SharedFlashAnchor.Observation(x: i < 12 ? 20 : 70, source: -0.3,
                rendered: i % 12 < 2 ? 0.08 : -0.12,
                material: i % 12 < 2 ? "foreground" : "background")
        }
        XCTAssertNil(SharedFlashAnchor.residual(observations, width: 96, trend: 0, amount: 0.5))
        let shared = observations.map {
            SharedFlashAnchor.Observation(x: $0.x, source: $0.source, rendered: -0.25, material: $0.material)
        }
        XCTAssertNotNil(SharedFlashAnchor.residual(shared, width: 96, trend: 0, amount: 0.5))
    }

    func testIdealPartialCorrectionAndIntentionalTrendRemainUntouched() {
        for strength in [0.25, 0.5, 0.75, 1.0] {
            let observations = (0..<16).map { i in
                SharedFlashAnchor.Observation(x: i < 8 ? 20 : 70,
                    source: -0.4, rendered: (1-strength)*(-0.4))
            }
            XCTAssertNil(SharedFlashAnchor.residual(observations, width: 96, trend: 0, amount: strength))
        }
        let fade = (0..<16).map { i in
            SharedFlashAnchor.Observation(x: i < 8 ? 20 : 70, source: -0.1, rendered: -0.1)
        }
        XCTAssertNil(SharedFlashAnchor.residual(fade, width: 96, trend: -0.1, amount: 0.5))
    }
}
