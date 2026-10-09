import XCTest
import AVFoundation
import AudioToolbox
import CoreImage
@testable import FrankLuma

final class ExposureTests: XCTestCase {


    func testProResPassthroughRetainsDecodedFramePixels() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov"), output = folder.appendingPathComponent("baseline.mov")
        try await makeTestVideo(at: source, variableTiming: true, frameCount: 8)
        try await VideoEngine.export(asset: AVURLAsset(url: source), curve: .empty, destination: output,
                                     options: .init(format: .proResMOV), progress: { _ in })
        var decoded: [[Int]] = []
        for url in [source, output] {
            let asset = AVURLAsset(url: url)
            let reader = try AVAssetReader(asset: asset)
            let track = try await asset.loadTracks(withMediaType: .video)[0]
            let frames = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            reader.add(frames); XCTAssertTrue(reader.startReading())
            var values: [Int] = []
            while let sample = frames.copyNextSampleBuffer(), let image = CMSampleBufferGetImageBuffer(sample) {
                CVPixelBufferLockBaseAddress(image, .readOnly)
                let data = CVPixelBufferGetBaseAddress(image)!.assumingMemoryBound(to: UInt8.self)
                values.append(Int(data[64 * CVPixelBufferGetBytesPerRow(image) + 96 * 4 + 2]))
                CVPixelBufferUnlockBaseAddress(image, .readOnly)
            }
            XCTAssertEqual(reader.status, .completed)
            decoded.append(values)
        }
        XCTAssertEqual(decoded[0].count, 8)
        XCTAssertEqual(decoded[1].count, 8)
        for (before, after) in zip(decoded[0], decoded[1]) {
            XCTAssertEqual(Double(after), Double(before), accuracy: 3)
        }
    }

    func testManualExposureUsesExactVariableDurationFramesAndReplacesExistingLayer() {
        let base = ExposureCurve(times: [0, 0.04, 0.21, 0.3], stops: [0.1, -0.2, 0.3, -0.1])
        let edited = base.addingManualAdjustments([1: 0.75, 3: -0.4])
        XCTAssertEqual(edited.stops, base.stops)
        XCTAssertEqual(edited.manualValue(at: 0.039), 0)
        XCTAssertEqual(edited.manualValue(at: 0.04), 0.75)
        XCTAssertEqual(edited.manualValue(at: 0.20), 0.75)
        XCTAssertEqual(edited.manualValue(at: 0.21), 0)
        XCTAssertEqual(edited.manualValue(at: 0.35), -0.4)
        XCTAssertEqual(edited.combinedStops[1], 0.55, accuracy: 0.000001)
        let replaced = edited.addingManualAdjustments([1: -0.25])
        XCTAssertEqual(replaced.manualStops, [0, -0.25, 0, 0])
        XCTAssertEqual(replaced.addingManualAdjustments([:]).combinedStops, base.stops)
        XCTAssertEqual(ExposureCurve.empty.manualValue(at: 1), 0)
    }

    func testManualFrameExposureMatchesPreviewAndExportWithoutAffectingAdjacentVFRFrames() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await makeTestVideo(at: source, variableTiming: true, frameCount: 8)
        let analysis = try await VideoEngine.analyse(url: source, region: nil, progress: { _ in })
        let times = analysis.samples.map(\.time)
        let curve = ExposureCurve(times: times, stops: Array(repeating: 0, count: times.count))
            .addingManualAdjustments([3: -1])
        for format in [ExportFormat.h264MOV, .proResMOV] {
            let output = folder.appendingPathComponent(format.rawValue + ".mov")
            try await VideoEngine.export(asset: AVURLAsset(url: source), curve: curve, destination: output,
                                         options: .init(format: format), progress: { _ in })
            let beforeTiming = try await sampleTiming(source), afterTiming = try await sampleTiming(output)
            XCTAssertEqual(beforeTiming.count, afterTiming.count)
            for (a, b) in zip(beforeTiming, afterTiming) {
                XCTAssertEqual(a.0, b.0, accuracy: 0.000001)
                XCTAssertEqual(a.1, b.1, accuracy: 0.000001)
            }
            let cs = CGColorSpace(name: CGColorSpace.linearSRGB)!
            let context = CIContext(options: [.workingColorSpace: cs])
            func luminance(_ frame: CGImage) -> Double {
                var pixel = [Float](repeating: 0, count: 4)
                let image = CIImage(cgImage: frame)
                pixel.withUnsafeMutableBytes {
                    context.render(image, toBitmap: $0.baseAddress!, rowBytes: 16,
                        bounds: CGRect(x: 96, y: 64, width: 1, height: 1), format: .RGBAf, colorSpace: cs)
                }
                return Double(pixel[0])
            }
            for frame in 2...4 {
                let original = try await VideoEngine.preview(url: source, time: times[frame], curve: .empty, frameEnd: times[frame + 1])
                let preview = try await VideoEngine.preview(url: source, time: times[frame], curve: curve, frameEnd: times[frame + 1])
                let exported = try await VideoEngine.preview(url: output, time: times[frame], curve: .empty, frameEnd: times[frame + 1])
                let expected = luminance(original) * (frame == 3 ? 0.5 : 1)
                XCTAssertEqual(luminance(preview), expected, accuracy: 0.005, "Preview frame \(frame)")
                XCTAssertEqual(luminance(exported), expected, accuracy: 0.015, "Export frame \(frame)")
            }
        }
    }

    func testShotTrendRejectsSlowFlickerAndFlashWithoutFlatteningRamp() {
        let samples = (0..<240).map { frame -> ExposureSample in
            let time = Double(frame) / 12
            let ramp = 0.015 * time
            let flicker = 0.3 * sin(2 * .pi * 0.8 * time)
            return ExposureSample(time: time, level: ramp + flicker + (frame == 119 ? 0.9 : 0), segment: 0)
        }
        let curve = ExposureMath.curve(samples: samples, radius: 0.5, strength: 1)
        let errors = (24..<216).map { samples[$0].level + curve.stops[$0] - 0.015 * samples[$0].time }
        XCTAssertLessThan(sqrt(errors.map { $0 * $0 }.reduce(0,+) / Double(errors.count)), 0.025)
        XCTAssertLessThan(abs(errors[119 - 24]), 0.03)
    }

    func testShotTrendPreservesVariableTimingRampAndIndependentSceneTargets() {
        let times = (0..<150).map { Double($0) * 0.07 + ($0.isMultiple(of: 3) ? 0.005 : 0) }
        let frames = times.map { ExposureSample(time: $0, level: -1.2 + 0.025 * $0, segment: 0) }
        let curve = ExposureMath.curve(samples: frames, radius: 0.5, strength: 1)
        XCTAssertLessThan(curve.peak, 0.000001)
        let differentShot = times.map { ExposureSample(time: $0 + 12, level: 3 + 0.025 * $0, segment: 1) }
        XCTAssertEqual(Array(ExposureMath.curve(samples: frames + differentShot, radius: 0.5, strength: 1).stops.prefix(frames.count)), curve.stops)
    }

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
        XCTAssertEqual(originalTiming.count, 48)
        XCTAssertEqual(originalTiming.count, exportTiming.count)
        for (before, after) in zip(originalTiming, exportTiming) {
            XCTAssertEqual(before.0, after.0, accuracy: 0.000001)
            XCTAssertEqual(before.1, after.1, accuracy: 0.000001)
        }
        print("Synthetic video flicker: \(before) EV → \(after) EV per frame")
    }

    func testHEVCRotatedVariableFrameRateExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("hevc.mov")
        let output = directory.appendingPathComponent("output.mov")
        try await makeTestVideo(at: source, codec: .hevc, variableTiming: true, rotated: true)
        let analysis = try await VideoEngine.analyse(url: source, region: nil, progress: { _ in })
        try await VideoEngine.export(asset: AVURLAsset(url: source), curve: .empty, destination: output, progress: { _ in })
        let info = try await VideoEngine.info(for: AVURLAsset(url: output))
        XCTAssertEqual(info.width, 128)
        XCTAssertEqual(info.height, 192)
        XCTAssertFalse(info.hasAudio)
        XCTAssertEqual(analysis.samples.count, 48)
        let before = try await sampleTiming(source)
        let after = try await sampleTiming(output)
        XCTAssertEqual(before.count, after.count)
        for (a,b) in zip(before,after) {
            XCTAssertEqual(a.0,b.0,accuracy:0.000001)
            XCTAssertEqual(a.1,b.1,accuracy:0.000001)
        }
    }

    func testCancelledExportLeavesExistingDestinationIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let destination = directory.appendingPathComponent("existing.mov")
        try await makeTestVideo(at: source)
        let original = Data("Existing user output".utf8)
        try original.write(to: destination)
        let staging = try ExportStaging(destination: destination)
        let task = Task {
            try await VideoEngine.export(asset: AVURLAsset(url: source), curve: .empty, destination: staging.file, progress: { _ in })
            try Task.checkCancellation()
            try staging.commit(to: destination)
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled export committed") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testInvalidVideoFailsCleanly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        try Data("Not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        do { _ = try await VideoEngine.info(for: AVURLAsset(url: url)); XCTFail("Invalid movie accepted") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testHDRAndOversizeSourcesAreRejectedWithActionableMessages() {
        XCTAssertTrue(MediaSupport.isHDRTransfer("SMPTE_ST_2084_PQ"))
        XCTAssertTrue(MediaSupport.isHDRTransfer("ITU_R_2100_HLG"))
        XCTAssertFalse(MediaSupport.isHDRTransfer("ITU_R_709_2"))
        for info in [VideoInfo(duration: 3, width: 1920, height: 1080, fps: 24, hasAudio: false, isHDR: true),
                     VideoInfo(duration: 3, width: 7680, height: 4320, fps: 24, hasAudio: false, isHDR: false)] {
            XCTAssertThrowsError(try MediaSupport.validate(info)) { error in
                XCTAssertTrue(error.localizedDescription.contains("SDR"))
            }
        }
        XCTAssertNoThrow(try MediaSupport.validate(VideoInfo(duration: 3, width: 3840, height: 2160, fps: 24, hasAudio: false, isHDR: false)))
    }

    func testDiskFullUnderlyingErrorOffersRecovery() {
        let diskFull = NSError(domain: NSPOSIXErrorDomain, code: 28)
        let wrapper = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: diskFull])
        XCTAssertTrue(MediaSupport.exportFailure(wrapper).contains("ran out of storage"))
        XCTAssertTrue(MediaSupport.exportFailure(wrapper).contains("not replaced"))
    }

    func testOneMinuteSDRAnalysisAndExport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("minute.mov")
        let output = folder.appendingPathComponent("output.mov")
        try await makeTestVideo(at: source, frameCount: 1440)
        let result = try await VideoEngine.analyse(url: source, region: nil, progress: { _ in })
        XCTAssertEqual(result.samples.count, 1440)
        try await VideoEngine.export(asset: AVURLAsset(url: source), curve: .empty, destination: output, progress: { _ in })
        let timing = try await sampleTiming(output)
        XCTAssertEqual(timing.count, 1440)
        let info = try await VideoEngine.info(for: AVURLAsset(url: output))
        XCTAssertEqual(info.duration, 60, accuracy: 0.01)
    }

    func testBundledDemoShowsMeasurableFlickerReduction() async throws {
        let repositoryDemo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/FrankLuma Demo.mov")
        let source = Bundle.main.url(forResource: "FrankLuma Demo", withExtension: "mov") ?? repositoryDemo
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Demo export validation requires the bundled or repository demo movie")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: output) }
        let analysis = try await VideoEngine.analyse(url: source, region: nil, progress: { _ in })
        XCTAssertEqual(analysis.samples.count, 96)
        let curve = SceneCorrection.curve(base: analysis.samples, boundaries: SceneMath.boundaries(in: analysis.samples), settings: [:], references: [:])
        try await VideoEngine.export(asset: AVURLAsset(url: source), curve: curve, destination: output, progress: { _ in })
        let corrected = try await VideoEngine.analyse(url: output, region: nil, progress: { _ in })
        XCTAssertLessThan(variation(corrected.samples), variation(analysis.samples) * 0.5)
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
            // Compressed readers also emit non-media/end-marker buffers.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample)
            XCTAssertTrue(time.isNumeric)
            guard time.isNumeric else { continue }
            result.append((time.seconds, CMSampleBufferGetDuration(sample).seconds))
        }
        XCTAssertEqual(reader.status, .completed)
        let sorted = result.sorted { $0.0 < $1.0 }
        let end = try await track.load(.timeRange).end.seconds
        // AVAssetReader can omit the final compressed sample's duration.
        // Compare its actual presentation interval instead of NaN with NaN.
        return sorted.indices.map { i in
            let duration = sorted[i].1
            return (sorted[i].0, duration.isFinite && duration > 0 ? duration :
                    (i+1 < sorted.count ? sorted[i+1].0 : end)-sorted[i].0)
        }
    }

    func testAllExportFormatsPreserveRotatedVariableFrameTiming() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.mov")
        try await makeTestVideo(at: source, variableTiming: true, rotated: true, frameCount: 12)
        let expected = try await sampleTiming(source)
        for format in ExportFormat.allCases {
            let destination = folder.appendingPathComponent(format.rawValue + "." + format.fileExtension)
            try await VideoEngine.export(asset: AVURLAsset(url: source), curve: .empty,
                                         destination: destination, options: .init(format: format), progress: { _ in })
            let asset = AVURLAsset(url: destination)
            let info = try await VideoEngine.info(for: asset)
            XCTAssertEqual(info.width, 128, format.title)
            XCTAssertEqual(info.height, 192, format.title)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            let expectedCodec: FourCharCode = format.codec == .h264 ? kCMVideoCodecType_H264 :
                (format.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_AppleProRes422)
            XCTAssertEqual(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) }, expectedCodec)
            let actual = try await sampleTiming(destination)
            XCTAssertEqual(actual.count, expected.count, format.title)
            for (a, b) in zip(actual, expected) {
                XCTAssertEqual(a.0, b.0, accuracy: 0.000001, format.title)
                XCTAssertEqual(a.1, b.1, accuracy: 0.000001, format.title)
            }
            // The ProRes output also exercises input decoding and analysis.
            if format == .proResMOV {
                let analysis = try await VideoEngine.analyse(url: destination, region: nil, progress: { _ in })
                XCTAssertEqual(analysis.samples.count, expected.count)
            }
        }
    }

    func testMP4ConvertsPCMAndPreservesAudioTail() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let video = folder.appendingPathComponent("video.mov")
        try await makeTestVideo(at: video, frameCount: 12)
        let wav = folder.appendingPathComponent("audio.wav")
        do {
            let audioFile = try AVAudioFile(forWriting: wav, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: 48000))
            buffer.frameLength = 48000
            let data = try XCTUnwrap(buffer.floatChannelData)
            for i in 0..<48000 { data[0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000) * 0.2) }
            try audioFile.write(from: buffer)
        } // Close the WAV writer before reading its finalised header.
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video), audioAsset = AVURLAsset(url: wav)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        let audioTrack = try XCTUnwrap(audioTracks.first)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 0.5, preferredTimescale: 24)), of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            .insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 48000)), of: audioTrack, at: .zero)
        let combined = folder.appendingPathComponent("combined.mov")
        let muxer = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        muxer.outputURL = combined
        muxer.outputFileType = .mov
        await muxer.export()
        XCTAssertEqual(muxer.status, .completed)
        if let error = muxer.error { throw error }
        for format in [ExportFormat.h264MP4, .hevcMP4, .h264MOV] {
            let destination = folder.appendingPathComponent(format.rawValue + "." + format.fileExtension)
            try await VideoEngine.export(asset: AVURLAsset(url: combined), curve: .empty, destination: destination,
                                         options: .init(format: format), progress: { _ in })
            let asset = AVURLAsset(url: destination)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let track = try XCTUnwrap(tracks.first)
            let descriptions = try await track.load(.formatDescriptions)
            XCTAssertEqual(descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) },
                           format.isMP4 ? kAudioFormatMPEG4AAC : kAudioFormatLinearPCM)
            let end = try await track.load(.timeRange).end.seconds
            XCTAssertEqual(end, 1, accuracy: 0.03)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(output)
            XCTAssertTrue(reader.startReading())
            var count = 0
            while let sample = output.copyNextSampleBuffer() { count += CMSampleBufferGetNumSamples(sample) }
            XCTAssertEqual(reader.status, .completed)
            XCTAssertGreaterThan(count, 46000)
        }
    }

    private func variation(_ samples: [ExposureSample]) -> Double {
        zip(samples, samples.dropFirst()).map { abs($1.level - $0.level) }.reduce(0, +) / Double(samples.count - 1)
    }

    private func makeTestVideo(at url: URL, codec: AVVideoCodecType = .h264, variableTiming: Bool = false, rotated: Bool = false, frameCount: Int = 48) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: 192, AVVideoHeightKey: 128
        ])
        if rotated { input.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 128, ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 192, kCVPixelBufferHeightKey as String: 128,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? VideoError.message("Test video writer could not start.") }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<frameCount {
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
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(variableTiming ? (frame / 2) * 3 + frame % 2 : frame), timescale: 24)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }
}
