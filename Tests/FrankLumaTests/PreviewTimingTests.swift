import XCTest
@testable import FrankLuma

final class PreviewTimingTests: XCTestCase {
    func testFlashFrameRequestIsInsideItsSampleAtTwelveFPS() {
        let start = 13.0/12, end = 14.0/12
        let request = PreviewTiming.interiorTime(start: start, end: end)
        XCTAssertGreaterThan(request, start)
        XCTAssertLessThan(request, end)
        let curve = ExposureCurve(times: [12.0/12,start,end], stops: [-0.05,0.38,-0.04])
        XCTAssertEqual(curve.value(at: request),0.38)
        // An unexpectedly earlier decoded sample must receive its own gain.
        XCTAssertEqual(curve.value(at: 12.0/12),-0.05)
    }
    func testVariableSampleDurationsAndFinalSample() {
        for (start,end) in [(0.0,0.04),(0.04,0.21),(7.083333333,7.166666667)] {
            let request=PreviewTiming.interiorTime(start:start,end:end)
            XCTAssertGreaterThan(request,start)
            XCTAssertLessThan(request,end)
        }
        XCTAssertEqual(PreviewTiming.interiorTime(start:2,end:nil),2)
    }
}
