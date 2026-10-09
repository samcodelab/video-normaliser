import XCTest
@testable import FrankLuma

final class PulseGainCompositionTests: XCTestCase {
    func testAdditionalCorrectionMustExceedScaledSourceUncertainty() throws {
        let C = CommonIlluminationComponent.self
        XCTAssertEqual(C.significantPulseDelta(0.001,heldError:0.006,strength:1,spatial:1),0)
        XCTAssertEqual(C.significantPulseDelta(-0.001,heldError:0.006,strength:1,spatial:1),0)
        XCTAssertEqual(C.significantPulseDelta(0.04,heldError:0.006,strength:1,spatial:1),0.04)
        XCTAssertEqual(C.significantPulseDelta(-0.04,heldError:0.006,strength:1,spatial:1),-0.04)
        XCTAssertEqual(C.significantPulseDelta(0.001,heldError:0,strength:1,spatial:1),0)
        // Both the correction target and its uncertainty scale with the user's
        // amounts, so partial controls do not lose otherwise significant evidence.
        XCTAssertEqual(C.significantPulseDelta(0.01,heldError:0.006,strength:0.5,spatial:0.5),0.01)
        XCTAssertEqual(C.significantPulseDelta(0.002,heldError:0.006,strength:0.5,spatial:0.5),0)
        XCTAssertEqual(C.significantPulseDelta(0.04,heldError:0.006,strength:0,spatial:1),0)
        XCTAssertNil(C.significantPulseDelta(0.04,heldError:.nan,strength:1,spatial:1))
        XCTAssertNil(C.significantPulseDelta(.nan,heldError:0,strength:1,spatial:1))
    }

    func testErrorAllowanceCannotAccumulateAcrossRefinementSteps() {
        XCTAssertFalse(CommonIlluminationComponent.pulseErrorWithinBudget(proposed:0.03,current:0.019,initial:0,allowance:0.02))
        XCTAssertFalse(CommonIlluminationComponent.pulseErrorWithinBudget(proposed:-0.03,current:-0.019,initial:0,allowance:0.02))
        XCTAssertTrue(CommonIlluminationComponent.pulseErrorWithinBudget(proposed:0.01,current:0.019,initial:0,allowance:0.02))
        XCTAssertFalse(CommonIlluminationComponent.pulseErrorWithinBudget(proposed:0.014,current:0.008,initial:0,allowance:0.01))
        XCTAssertFalse(CommonIlluminationComponent.pulseErrorWithinBudget(proposed:.nan,current:0,initial:0,allowance:0.02))
    }
    func testRefinementUsesRemainingBudgetForBothDirections() throws {
        let old = [0.20,-0.10,0],proposed = [0.30,-0.40,0.10]
        let scale = try XCTUnwrap(CommonIlluminationComponent.boundedRefinementScale(current:old,proposed:proposed,limit:0.25))
        XCTAssertEqual(scale,0.5,accuracy:1e-12)
        for (a,b) in zip(old,proposed) { XCTAssertLessThanOrEqual(abs(a+scale*(b-a)),0.25+1e-12) }
        XCTAssertEqual(CommonIlluminationComponent.boundedRefinementScale(current:[0.25],proposed:[0.30],limit:0.25),0)
        XCTAssertEqual(CommonIlluminationComponent.boundedRefinementScale(current:[0.25],proposed:[0.10],limit:0.25),1)
        XCTAssertNil(CommonIlluminationComponent.boundedRefinementScale(current:[0.30],proposed:[0],limit:0.25))
        XCTAssertNil(CommonIlluminationComponent.boundedRefinementScale(current:[0],proposed:[.nan],limit:0.25))
    }
    func testAlreadyCorrectedFlashIsNotCorrectedTwice() throws {
        let delta = try XCTUnwrap(CommonIlluminationComponent.pulseAdditionalCurvature(
            sourceExcursion: 0.804, automaticGain: -0.802, globalGain: -0.802,
            strength: 1, spatial: 1))
        XCTAssertEqual(0.804-0.802+delta, 0, accuracy: 1e-12)
        XCTAssertLessThan(abs(delta), 0.003)
    }

    func testOppositeLocalErrorsRequireOppositeCorrections() throws {
        let dark = try XCTUnwrap(CommonIlluminationComponent.pulseAdditionalCurvature(
            sourceExcursion: 0.188, automaticGain: -0.333, globalGain: -0.35,
            strength: 1, spatial: 1))
        let bright = try XCTUnwrap(CommonIlluminationComponent.pulseAdditionalCurvature(
            sourceExcursion: 0.37, automaticGain: -0.32, globalGain: -0.35,
            strength: 1, spatial: 1))
        XCTAssertGreaterThan(dark, 0)
        XCTAssertLessThan(bright, 0)
        XCTAssertEqual(0.188-0.333+dark, 0, accuracy: 1e-12)
        XCTAssertEqual(0.37-0.32+bright, 0, accuracy: 1e-12)
    }

    func testPartialSlidersRetainTheirRequestedTarget() throws {
        // Half strength asks for half the source flash to remain. Half spatial
        // blends that local target with the already strength-scaled global gain.
        let delta = try XCTUnwrap(CommonIlluminationComponent.pulseAdditionalCurvature(
            sourceExcursion: 0.2, automaticGain: -0.15, globalGain: -0.18,
            strength: 0.5, spatial: 0.5))
        XCTAssertEqual(0.2-0.15+delta, 0.06, accuracy: 1e-12)
    }

    func testUnknownAndUnsafeEvidenceIsNotClampedIntoCorrection() {
        XCTAssertNil(CommonIlluminationComponent.pulseAdditionalCurvature(
            sourceExcursion: nil, automaticGain: 0, globalGain: 0, strength: 1, spatial: 1))
        XCTAssertNil(CommonIlluminationComponent.pulseAdditionalCurvature(
            sourceExcursion: 0.8, automaticGain: 0, globalGain: 0, strength: 1, spatial: 1))
        XCTAssertNil(CommonIlluminationComponent.pulseAdditionalCurvature(
            sourceExcursion: .nan, automaticGain: 0, globalGain: 0, strength: 1, spatial: 1))
        XCTAssertEqual(CommonIlluminationComponent.pulseAdditionalCurvature(
            sourceExcursion: nil, automaticGain: nil, globalGain: nil, strength: 0, spatial: 1), 0)
        XCTAssertEqual(CommonIlluminationComponent.pulseAdditionalCurvature(
            sourceExcursion: nil, automaticGain: nil, globalGain: nil, strength: 1, spatial: 0), 0)
    }
}
