import XCTest
@testable import FrankLuma

final class PulseReconstructionTests: XCTestCase {
    func testBoundedFieldScaledPenaltyPreservesSolutionAndSourceBounds() throws {
        let rows: [PulseReconstruction.FieldRow] = [
            .init(terms:[(0,1)],error:0.1,budget:0.11,weight:1,adjacent:false,objectiveTolerance:0.02),
            .init(terms:[(0,1),(1,1)],error:0,budget:0.001,weight:0,adjacent:true)
        ]
        let solved = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:rows,bounds:[(-0.2,0.2),(-0.2,0.2),(-0.2,0.2)],maximumIterations:2000,convergenceTolerance:1e-10,boxPenalty:0.01))
        XCTAssertEqual(solved.increments[0],-0.08/1.002,accuracy:1e-8)
        XCTAssertEqual(solved.increments[0]+solved.increments[1],0,accuracy:1e-10)
        XCTAssertEqual(solved.increments[2],0)
        XCTAssertLessThanOrEqual(solved.primalResidual,1e-10)
        XCTAssertLessThanOrEqual(solved.dualResidual,1e-10)
        let bounded = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:rows,bounds:[(-0.02,0.02),(-0.2,0.2)],maximumIterations:2000,convergenceTolerance:1e-10,boxPenalty:0.01))
        XCTAssertEqual(bounded.increments[0],-0.02,accuracy:1e-8)
        XCTAssertLessThan(bounded.maximumViolation,1e-9)
        XCTAssertNil(PulseReconstruction.solveBoundedField(rows:rows,bounds:[(-1,1),(-1,1)],boxPenalty:0))
    }
    func testBoundedFieldSourceIntervalsAvoidFittingUncertainResiduals() throws {
        let pulse = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:[
            .init(terms:[(0,1)],error:0.1,budget:0.11,weight:1,adjacent:false,objectiveTolerance:0.02)
        ],bounds:[(-0.2,0.2)]))
        XCTAssertEqual(pulse.increments[0],-0.08/1.001,accuracy:1e-6)
        XCTAssertLessThan(abs(0.1+pulse.increments[0]),0.021)
        let uncertain = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:[
            .init(terms:[(0,1)],error:0.01,budget:0.02,weight:1,adjacent:false,objectiveTolerance:0.02)
        ],bounds:[(-0.2,0.2)]))
        XCTAssertEqual(uncertain.increments[0],0,accuracy:1e-10)
        let protected = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:[
            .init(terms:[(0,1)],error:0.1,budget:0.11,weight:1,adjacent:false,objectiveTolerance:0.02),
            .init(terms:[(0,1),(1,1)],error:0,budget:0.001,weight:0,adjacent:true)
        ],bounds:[(-0.2,0.2),(-0.2,0.2)],maximumIterations:2000,convergenceTolerance:1e-10))
        XCTAssertLessThan(protected.maximumViolation,1e-10)
        XCTAssertLessThanOrEqual(protected.primalResidual,1e-10)
        XCTAssertLessThanOrEqual(protected.dualResidual,1e-10)
        XCTAssertLessThan(abs(0.1+protected.increments[0]),0.021)
        XCTAssertEqual(protected.increments[0]+protected.increments[1],0,accuracy:1e-10)
        XCTAssertNil(PulseReconstruction.solveBoundedField(rows:[
            .init(terms:[(0,1)],error:0,budget:0.1,weight:1,adjacent:false,objectiveTolerance:-0.01)
        ],bounds:[(-1,1)]))
        XCTAssertNil(PulseReconstruction.solveBoundedField(rows:[
            .init(terms:[(0,1)],error:0,budget:0.1,weight:1,adjacent:false)
        ],bounds:[(-1,1)],convergenceTolerance:0))
    }
    func testBoundedFieldRestoresUnconvergedStepWithoutRelaxingProtections() throws {
        let rows: [PulseReconstruction.FieldRow] = [
            .init(terms:[(0,1)],error:1,budget:1,weight:1,adjacent:false),
            .init(terms:[(0,1)],error:0.01,budget:0.01,weight:0,adjacent:true),
            .init(terms:[(0,1)],error:0,budget:0.015,weight:0,adjacent:false)
        ]
        let unfinished = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:rows,bounds:[(-1,1)],maximumIterations:1))
        XCTAssertGreaterThan(unfinished.maximumViolation,0.01)
        let restored = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:rows,bounds:[(-1,1)],maximumIterations:1,restoreFeasibility:true))
        XCTAssertLessThan(restored.maximumViolation,1e-12)
        XCTAssertGreaterThan(restored.feasibilityScale,0)
        XCTAssertLessThan(restored.feasibilityScale,1)
        XCTAssertEqual(restored.increments[0],-0.015,accuracy:1e-9)
        XCTAssertLessThanOrEqual(pow(0.01+restored.increments[0],2),0.0001)
        XCTAssertLessThan(abs(1+restored.increments[0]),1)
        let quiet = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:[
            .init(terms:[(0,1)],error:1,budget:1,weight:1,adjacent:false),
            .init(terms:[(0,1)],error:0,budget:0.01,weight:0,adjacent:true)
        ],bounds:[(-1,1)],maximumIterations:1,restoreFeasibility:true))
        XCTAssertEqual(quiet.increments,[0])
        XCTAssertEqual(quiet.maximumViolation,0)
    }
    func testBoundedFieldJointlyPreservesProtectedResponseAndSourceBudgets() throws {
        let rows: [PulseReconstruction.FieldRow] = [
            .init(terms:[(0,1)],error:0.1,budget:0.11,weight:1,adjacent:false),
            .init(terms:[(0,1),(1,1)],error:0,budget:0.001,weight:0,adjacent:true)
        ]
        let step = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:rows,bounds:[(-0.2,0.2),(-0.2,0.2),(-0.2,0.2)]))
        XCTAssertLessThan(step.maximumViolation,0.000001)
        XCTAssertEqual(step.increments[0],-0.1/1.002,accuracy:0.00001)
        XCTAssertEqual(step.increments[0]+step.increments[1],0,accuracy:0.000001)
        XCTAssertEqual(step.increments[2],0)
        let bounded = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:rows,bounds:[(-0.02,0.02),(-0.2,0.2)]))
        XCTAssertLessThan(bounded.maximumViolation,0.000001)
        XCTAssertEqual(bounded.increments[0],-0.02,accuracy:0.000001)
        XCTAssertEqual(bounded.increments[1],0.02,accuracy:0.000001)
    }

    func testBoundedFieldProtectsAggregateAdjacentEnergyAndRejectsInvalidInputs() throws {
        let rows: [PulseReconstruction.FieldRow] = [
            .init(terms:[(0,1)],error:0.1,budget:0.11,weight:0,adjacent:true),
            .init(terms:[(1,1)],error:0,budget:0.11,weight:0,adjacent:true),
            .init(terms:[(1,1)],error:0.2,budget:0.21,weight:1,adjacent:false)
        ]
        let step = try XCTUnwrap(PulseReconstruction.solveBoundedField(rows:rows,bounds:[(-0.2,0.2),(-0.2,0.2)],maximumIterations:1000))
        XCTAssertLessThan(step.maximumViolation,0.000001)
        let energy = pow(0.1+step.increments[0],2)+pow(step.increments[1],2)
        XCTAssertLessThanOrEqual(energy,0.01000001)
        XCTAssertLessThan(0.2+step.increments[1],0.11)
        XCTAssertNil(PulseReconstruction.solveBoundedField(rows:rows,bounds:[(0.1,0.2),(-0.2,0.2)]))
        XCTAssertNil(PulseReconstruction.solveBoundedField(rows:[.init(terms:[(2,1)],error:0,budget:0,weight:1,adjacent:false)],bounds:[(-1,1)]))
    }

    func testResidualConsistencyUsesMeasuredErrorAndControlScale() {
        XCTAssertTrue(PulseReconstruction.residualsConsistent([0.009,0.03],errors:[0.001,0.02],scale:1))
        XCTAssertFalse(PulseReconstruction.residualsConsistent([0.011,0.03],errors:[0.001,0.02],scale:1))
        XCTAssertFalse(PulseReconstruction.residualsConsistent([0.03],errors:[0.02],scale:0.5))
        XCTAssertFalse(PulseReconstruction.residualsConsistent([.nan],errors:[0.02],scale:1))
        XCTAssertFalse(PulseReconstruction.residualsConsistent([0],errors:[],scale:1))
    }
    func testSupplementCannotModifyProtectedMiddleFrames() throws {
        let result = try XCTUnwrap(PulseReconstruction.solveCorrections(times:(0..<7).map(Double.init),constraints:[
            .init(before:0,middle:2,after:4,excursion:0.2,weight:1),
            .init(before:3,middle:4,after:5,excursion:0,weight:1)
        ],regularization:0,variableFrames:[2]))
        XCTAssertEqual(try XCTUnwrap(result.signal[2]),0.2,accuracy:1e-8)
        XCTAssertNil(result.signal[4])
        XCTAssertLessThan(result.maximumResidual,1e-8)
    }
    func testJointIntervalsRecoverPulseWithoutAdjustingUnsupportedFrames() throws {
        let times = [0.0,0.04,0.12,0.15,0.24,0.31,0.5]
        let expected = [0.0,0,0.12,-0.08,0.20,0,0]
        let indices = [(1,2,3),(2,3,4),(3,4,5),(0,2,4),(1,3,5),(2,4,6)]
        let rows = indices.map { a,b,c -> PulseReconstruction.Constraint in
            let alpha = (times[b]-times[a])/(times[c]-times[a])
            return .init(before:a,middle:b,after:c,excursion:expected[b]-(1-alpha)*expected[a]-alpha*expected[c],weight:1)
        }
        let result = try XCTUnwrap(PulseReconstruction.solveCorrections(times:times,constraints:rows,regularization:0))
        for i in [2,3,4] { XCTAssertEqual(try XCTUnwrap(result.signal[i]),expected[i],accuracy:1e-8) }
        for i in [0,1,5,6] { XCTAssertNil(result.signal[i]) }
        XCTAssertLessThan(result.maximumResidual,1e-8)
    }

    func testWiderSupportedMiddleDoesNotFillInterveningFrames() throws {
        let result = try XCTUnwrap(PulseReconstruction.solveCorrections(times:(0..<7).map(Double.init),
            constraints:[.init(before:1,middle:3,after:5,excursion:0.2,weight:1)],regularization:0))
        XCTAssertEqual(try XCTUnwrap(result.signal[3]),0.2,accuracy:1e-8)
        for i in [0,1,2,4,5,6] { XCTAssertNil(result.signal[i]) }
        XCTAssertNil(PulseReconstruction.solveCorrections(times:[0,1,2],constraints:[.init(before:0,middle:1,after:3,excursion:0,weight:1)]))
    }
    func testSingleFlashDoesNotBecomeThreeSeparateCorrections() throws {
        let times = (0..<9).map(Double.init)
        let excursions: [Double?] = [nil,0,0,-0.45,0.9,-0.45,0,0,nil]
        let result = try XCTUnwrap(PulseReconstruction.solve(times: times, excursions: excursions,
            weights: [Double](repeating: 1,count: 9),regularization: 0))
        let signal = try result.signal.map { try XCTUnwrap($0) }
        for i in signal.indices { XCTAssertEqual(signal[i],i == 4 ? 0.8 : -0.1,accuracy: 1e-8) }
        XCTAssertLessThan(result.maximumResidual,1e-8)
    }

    func testVariableFrameTimingAndLinearNullspace() throws {
        let times = [0.0,0.04,0.12,0.15,0.24,0.31,0.5]
        let source = times.enumerated().map { 0.3+0.7*$0.element+($0.offset == 3 ? 0.8 : 0) }
        var r = [Double?](repeating:nil,count:times.count)
        for i in 1..<times.count-1 {
            let alpha = (times[i]-times[i-1])/(times[i+1]-times[i-1])
            r[i] = source[i]-(1-alpha)*source[i-1]-alpha*source[i+1]
        }
        let result = try XCTUnwrap(PulseReconstruction.solve(times:times,excursions:r,
            weights:[Double](repeating:1,count:times.count),regularization:0))
        XCTAssertLessThan(result.maximumResidual,1e-8)
        let x = try result.signal.map { try XCTUnwrap($0) }
        XCTAssertEqual(x.reduce(0,+),0,accuracy:1e-8)
        XCTAssertEqual(zip(x,times).reduce(0) { $0+$1.0*$1.1 },0,accuracy:1e-8)
        XCTAssertGreaterThan(x[3],x[2]+0.5)
    }

    func testUnknownEvidenceIsNotZeroFilled() throws {
        let result = try XCTUnwrap(PulseReconstruction.solve(times:(0..<9).map(Double.init),
            excursions:[nil,0,0,nil,nil,nil,0,0,nil],weights:[Double](repeating:1,count:9)))
        XCTAssertNil(result.signal[4])
        XCTAssertEqual(result.signal[1],0)
        XCTAssertEqual(result.signal[7],0)
    }

    func testInvalidTimingIsRejected() {
        XCTAssertNil(PulseReconstruction.solve(times:[0,0,1],excursions:[nil,0,nil],weights:[1,1,1]))
    }

    func testCorrectionAnchorsPreserveGainAtUnknownBoundary() throws {
        let times = [0.0,0.1,0.25,0.3,0.5,0.6,0.8]
        let rows: [Double?] = [nil,-0.1,0.2,nil,-0.15,0.05,nil]
        let result = try XCTUnwrap(PulseReconstruction.solve(times:times,excursions:rows,
            weights:[Double](repeating:1,count:times.count),regularization:0,anchorEndpoints:true))
        XCTAssertNil(result.signal[3]) // Unknown source evidence remains unknown.
        XCTAssertEqual(result.signal[0],0)
        XCTAssertEqual(result.signal[6],0)
        // The unknown boundary receives no extra gain. Both independently
        // supported runs still reproduce their requested correction curvature.
        let applied = result.signal.map { $0 ?? 0 }
        for i in 1..<times.count-1 {
            guard let expected = rows[i] else { continue }
            let alpha = (times[i]-times[i-1])/(times[i+1]-times[i-1])
            XCTAssertEqual(applied[i]-(1-alpha)*applied[i-1]-alpha*applied[i+1],expected,accuracy:1e-8)
        }
    }
}
