import XCTest
import CoreImage
import CoreVideo
import AVFoundation
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

    func testExportPreservesRoundedEditEndWhenDecoderOmitsDurations() async throws {
        // Self-generated MPEG-4 fixture: three frames at 29 fps; the MOV edit
        // list rounds the presentation end to 104/1000 while sample ticks use
        // 14848 Hz. AVFoundation omits the decoded frame durations.
        let source = try XCTUnwrap(TestResources.bundle.url(forResource: "rounded-edit-padding",withExtension: "mov",subdirectory: "Fixtures"))
        let asset = AVURLAsset(url: source),track = try await asset.loadTracks(withMediaType: .video)[0]
        let range = try await track.load(.timeRange)
        XCTAssertEqual(CMTimeCompare(range.end,CMTime(value: 104,timescale: 1000)),0)
        let reader = try AVAssetReader(asset: asset)
        let samples = AVAssetReaderTrackOutput(track: track,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(samples);XCTAssertTrue(reader.startReading())
        var times = [CMTime](),lastDuration = CMTime.invalid
        while let sample = samples.copyNextSampleBuffer() {
            times.append(CMSampleBufferGetPresentationTimeStamp(sample));lastDuration = CMSampleBufferGetDuration(sample)
        }
        XCTAssertEqual(times.count,3)
        XCTAssertFalse(lastDuration.isNumeric)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mov")
        defer { try? FileManager.default.removeItem(at: output) }
        try await VideoEngine.export(asset: asset,curve: .empty,destination: output,progress: { _ in })
        let rendered = AVURLAsset(url: output),outTrack = try await rendered.loadTracks(withMediaType: .video)[0]
        let outRange = try await outTrack.load(.timeRange)
        XCTAssertEqual(CMTimeCompare(range.end,outRange.end),0,"The original edit-list hold must remain exact")
        let outReader = try AVAssetReader(asset: rendered)
        let outSamples = AVAssetReaderTrackOutput(track: outTrack,outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        outReader.add(outSamples);XCTAssertTrue(outReader.startReading())
        var outTimes = [CMTime]()
        while let sample = outSamples.copyNextSampleBuffer() { outTimes.append(CMSampleBufferGetPresentationTimeStamp(sample)) }
        XCTAssertEqual(outTimes.count,times.count)
        XCTAssertTrue(zip(times,outTimes).allSatisfy { CMTimeCompare($0,$1) == 0 })
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
