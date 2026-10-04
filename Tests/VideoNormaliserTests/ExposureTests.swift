import XCTest
import AVFoundation
@testable import VideoNormaliser

final class ExposureTests: XCTestCase {
    func testMedianRejectsMovingForeground() {
        let before = [Double](repeating: 0.2, count: 100)
        let after = [Double](repeating: 0.4, count: 75) + [Double](repeating: 0.05, count: 25)
        let transition = ExposureMath.transition(previous: before, current: after)
        XCTAssertEqual(transition.delta, 1, accuracy: 0.0001)
        XCTAssertTrue(transition.reliable)
        XCTAssertFalse(transition.cut)
    }

    func testFlickerReducedAndSlowRampPreserved() {
        let samples = (0..<240).map { i in
            ExposureSample(time: Double(i) / 24, level: Double(i) * 0.002 + (i.isMultiple(of: 2) ? 0.3 : -0.3), segment: 0)
        }
        let curve = ExposureMath.curve(samples: samples, radius: 0.5, strength: 1)
        for i in 24..<216 {
            XCTAssertEqual(samples[i].level + curve.stops[i], Double(i) * 0.002, accuracy: 0.02)
        }
        XCTAssertEqual(ExposureMath.curve(samples: samples, radius: 0.5, strength: 0).peak, 0)
    }

    func testCutsDoNotBlendAndLookupHoldsPerFrame() {
        let samples = (0..<48).map { i in
            ExposureSample(time: Double(i) / 24, level: i < 24 ? 0 : 3, segment: i < 24 ? 0 : 1)
        }
        XCTAssertEqual(ExposureMath.curve(samples: samples, radius: 1, strength: 1).peak, 0)
        let curve = ExposureCurve(times: [0, 1, 2], stops: [0.3, -0.2, 0.1])
        XCTAssertEqual(curve.value(at: 0.9), 0.3)
        XCTAssertEqual(curve.value(at: 1), -0.2)
        XCTAssertEqual(curve.value(at: 10), 0.1)
    }

    func testClippedFramesAreUncertain() {
        let transition = ExposureMath.transition(previous: Array(repeating: 1, count: 100), current: Array(repeating: 1, count: 100))
        XCTAssertFalse(transition.reliable)
        XCTAssertEqual(transition.delta, 0)
    }

    func testRealVideoAnalysisAndExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("flicker.mov")
        let destination = directory.appendingPathComponent("corrected.mov")
        try await makeTestVideo(at: source)
        let analysis = try await VideoEngine.analyse(url: source, region: nil, progress: { _ in })
        XCTAssertEqual(analysis.samples.count, 48)
        XCTAssertEqual(analysis.uncertainFrames, 0)
        let curve = SceneCorrection.curve(base: analysis.samples, boundaries: SceneMath.boundaries(in: analysis.samples), settings: [:], references: [:])
        XCTAssertGreaterThan(curve.peak, 0.3)
        try await VideoEngine.export(asset: AVURLAsset(url: source), curve: curve, destination: destination, progress: { _ in })
        let corrected = try await VideoEngine.analyse(url: destination, region: nil, progress: { _ in })
        let before = variation(analysis.samples)
        let after = variation(corrected.samples)
        XCTAssertLessThan(after, before * 0.2, "Export should remove at least 80% of alternating exposure flicker")
        let sourceInfo = try await VideoEngine.info(for: AVURLAsset(url: source))
        let outputInfo = try await VideoEngine.info(for: AVURLAsset(url: destination))
        XCTAssertEqual(sourceInfo.width, outputInfo.width)
        XCTAssertEqual(sourceInfo.height, outputInfo.height)
        XCTAssertEqual(sourceInfo.duration, outputInfo.duration, accuracy: 0.05)
        XCTAssertEqual(sourceInfo.fps, outputInfo.fps, accuracy: 0.01)
        XCTAssertEqual(corrected.samples.count, analysis.samples.count)
        let originalTiming = try await sampleTiming(source)
        let exportTiming = try await sampleTiming(destination)
        XCTAssertEqual(originalTiming.count, exportTiming.count)
        for (before, after) in zip(originalTiming, exportTiming) {
            XCTAssertEqual(before.0, after.0, accuracy: 0.000001)
            XCTAssertEqual(before.1, after.1, accuracy: 0.000001)
        }
        print("Synthetic video flicker: \(before) EV → \(after) EV per frame")
    }

    private func sampleTiming(_ url: URL) async throws -> [(Double, Double)] {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var result: [(Double, Double)] = []
        while let sample = output.copyNextSampleBuffer() {
            result.append((CMSampleBufferGetPresentationTimeStamp(sample).seconds, CMSampleBufferGetDuration(sample).seconds))
        }
        XCTAssertEqual(reader.status, .completed)
        return result.sorted { $0.0 < $1.0 }
    }

    private func variation(_ samples: [ExposureSample]) -> Double {
        zip(samples, samples.dropFirst()).map { abs($1.level - $0.level) }.reduce(0, +) / Double(samples.count - 1)
    }

    private func makeTestVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 192, AVVideoHeightKey: 128
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 192, kCVPixelBufferHeightKey as String: 128,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoError.message("Test video writer could not start.") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<48 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? VideoError.message("Test video writer stopped.") }
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixel: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 192, 128, kCVPixelFormatType_32BGRA,
                                               [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0..<128 { for x in 0..<192 {
                let offset = y * stride + x * 4
                let value = UInt8((frame.isMultiple(of: 2) ? 90 : 125) + x / 24)
                bytes[offset] = value; bytes[offset + 1] = value; bytes[offset + 2] = value; bytes[offset + 3] = 255
            } }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
