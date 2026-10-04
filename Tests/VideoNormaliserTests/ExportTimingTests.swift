import XCTest
@testable import VideoNormaliser

final class ExportTimingTests: XCTestCase {
    func testMovieTimescaleRepresentsVideoAndAudioEndsExactly() {
        XCTAssertEqual(ExportTiming.commonTimescale(600, 44100), 88200)
        XCTAssertEqual(ExportTiming.commonTimescale(600, 48000), 48000)
        XCTAssertEqual(ExportTiming.commonTimescale(30000, 44100), 4410000)
        let scale = ExportTiming.commonTimescale(600, 44100)
        XCTAssertEqual(scale % 600, 0)
        XCTAssertEqual(scale % 44100, 0)
    }
    func testTimescaleCalculationDoesNotOverflow() {
        XCTAssertGreaterThan(ExportTiming.commonTimescale(Int32.max, Int32.max - 1), 0)
        XCTAssertEqual(ExportTiming.commonTimescale(0, 44100), 44100)
    }
}
