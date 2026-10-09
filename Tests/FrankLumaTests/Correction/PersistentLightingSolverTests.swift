import XCTest
@testable import FrankLuma

final class PersistentLightingSolverTests: XCTestCase {
    func testWeightedExposureConstraintAndInvalidImportance() throws {
        let pixel = PersistentLightingSolver.Pixel(light: 0.3,weights: [.init(index: 0,value: 1)])
        let before = [PersistentLightingSolver.Pixel(light: 0.3,weights: [])]
        let samples = [PersistentLightingSolver.Sample(before: before,after: [pixel],target: 0.1),
                       PersistentLightingSolver.Sample(before: before,after: [pixel],target: -0.1,importance: 9)]
        let fit = try XCTUnwrap(PersistentLightingSolver.fit(.init(samples: samples,count: 1,ridge: 1e-8,limit: 0.25)))
        XCTAssertEqual(fit[0],-0.08,accuracy: 1e-7)
        let invalid = PersistentLightingSolver.Sample(before: before,after: [pixel],target: 0,importance: -1)
        XCTAssertNil(PersistentLightingSolver.fit(.init(samples: [invalid],count: 1,ridge: 0.05,limit: 0.25)))
    }
    func testIndependentSurfaceGainsAndZeroStrength() throws {
        let truth = [0.12,-0.08]
        let samples = (0..<2).map { i in
            PersistentLightingSolver.Sample(before: [.init(light: 0.3, weights: [])],
                after: [.init(light: 0.3*exp2(-truth[i]),weights: [.init(index: i,value: 1)])],target: 0)
        }
        let gains = try XCTUnwrap(PersistentLightingSolver.fit(.init(samples: samples,count: 2,ridge: 1e-8,limit: 0.25)))
        for i in truth.indices { XCTAssertEqual(gains[i],truth[i],accuracy: 1e-7) }
        XCTAssertEqual(PersistentLightingSolver.fit(.init(samples: samples,count: 2,ridge: 0.05,limit: 0)),[0,0])
    }

    func testTemporalJacobianAndInvalidSupport() throws {
        let sample = PersistentLightingSolver.Sample(
            before: [.init(light: 0.3,weights: [.init(index: 0,value: 0.4)]),.init(light: 0.1,weights: [.init(index: 1,value: 0.6)])],
            after: [.init(light: 0.2,weights: [.init(index: 0,value: 0.7)]),.init(light: 0.2,weights: [.init(index: 1,value: 0.2)])],target: 0.03)
        let coefficients = [0.12,-0.08]
        let row = try XCTUnwrap(PersistentLightingSolver.response(sample,coefficients: coefficients))
        for i in coefficients.indices {
            var changed = coefficients; changed[i] += 1e-6
            let next = try XCTUnwrap(PersistentLightingSolver.response(sample,coefficients: changed))
            XCTAssertEqual((next.error-row.error)/1e-6,row.jacobian[i] ?? 0,accuracy: 1e-6)
        }
        XCTAssertNil(PersistentLightingSolver.response(sample,coefficients: []))
        XCTAssertNil(PersistentLightingSolver.fit(.init(samples: [sample],count: 2,ridge: 0,limit: 0.25)))
    }
}
