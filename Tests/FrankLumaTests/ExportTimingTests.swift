import XCTest
import CoreImage
import CoreVideo
@testable import FrankLuma

final class ExportTimingTests: XCTestCase {
    func testHighPrecisionRenderRetainsSubEightBitStepsAndChannelOrder() throws {
        let width = 1024
        let pixels = (0..<width).flatMap { x -> [Float] in
            [0.2 + Float(x) / Float(width) * 0.1, 0.5, 0.7, 1]
        }
        let image = CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: 1), format: .RGBAf,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, 1, kCVPixelFormatType_64ARGB, nil, &buffer), kCVReturnSuccess)
        let target = try XCTUnwrap(buffer)
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAh.rawValue])
        try VideoExporter.renderHighPrecision(image, to: target, context: context,
                                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        CVPixelBufferLockBaseAddress(target, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(target, .readOnly) }
        let values = try XCTUnwrap(CVPixelBufferGetBaseAddress(target)).assumingMemoryBound(to: UInt16.self)
        let reds = (0..<width).map { UInt16(bigEndian: values[$0 * 4 + 1]) }
        XCTAssertGreaterThan(Set(reds).count, 256, "ProRes rendering must retain more than 8-bit precision")
        XCTAssertEqual(Double(UInt16(bigEndian: values[0])) / 65535, 1, accuracy: 0.001)
        XCTAssertEqual(Double(reds[0]) / 65535, 0.2, accuracy: 0.002)
        XCTAssertEqual(Double(UInt16(bigEndian: values[2])) / 65535, 0.5, accuracy: 0.002)
        XCTAssertEqual(Double(UInt16(bigEndian: values[3])) / 65535, 0.7, accuracy: 0.002)
    }

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
