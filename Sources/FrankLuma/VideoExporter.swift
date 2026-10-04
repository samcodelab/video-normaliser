import AVFoundation
import CoreImage

/// Writes one output sample per decoded source sample, retaining its timestamp
/// and duration. Audio is passed through independently, including a longer tail.
enum VideoExporter {
    static func export(asset: AVAsset, curve: ExposureCurve, destination: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        try MediaSupport.validate(try await VideoEngine.info(for: asset))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.message("No video track found.")
        }
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let imageTransform = VideoGeometry.coreImageTransform(preferred: transform, naturalSize: size)
        let timeRange = try await track.load(.timeRange)
        let rate = try await track.load(.estimatedDataRate)
        let fps = try await track.load(.nominalFrameRate)
        let formats = try await track.load(.formatDescriptions)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.metadata = try await asset.load(.metadata)
        var movieScale = try await track.load(.naturalTimeScale)
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoError.message("This video format cannot be decoded. Try exporting an SDR H.264 copy first.") }
        reader.add(videoOutput)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(Double(rate) * 1.5, size.width * size.height * Double(max(1, fps)) * 0.16),
                AVVideoAllowFrameReorderingKey: false
            ]
        ]
        if let format = formats.first, let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] {
            var colour: [String: Any] = [:]
            for (source, target) in [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimariesKey),
                                     (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunctionKey),
                                     (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrixKey)] {
                if let value = extensions[source as String] { colour[target] = value }
            }
            if !colour.isEmpty { settings[AVVideoColorPropertiesKey] = colour }
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw VideoError.message("This video's dimensions or colour settings cannot be exported as H.264. Try an SDR Rec. 709 copy with standard video dimensions.")
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.transform = transform
        videoInput.mediaTimeScale = try await track.load(.naturalTimeScale)
        guard writer.canAdd(videoInput) else { throw VideoError.message("The video cannot be encoded with these dimensions.") }
        writer.add(videoInput)
        var outputs: [AVAssetReaderTrackOutput] = [videoOutput]
        var inputs: [AVAssetWriterInput] = [videoInput]
        for audio in try await asset.loadTracks(withMediaType: .audio) {
            let audioScale = try await audio.load(.naturalTimeScale)
            movieScale = ExportTiming.commonTimescale(movieScale, audioScale)
            let audioFormats = try await audio.load(.formatDescriptions)
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormats.first)
            guard reader.canAdd(output), writer.canAdd(input) else { throw VideoError.message("An audio track cannot be preserved in QuickTime format.") }
            reader.add(output); writer.add(input)
            outputs.append(output); inputs.append(input)
        }
        // Keep edit-list ends exact as well as sample timestamps. The default
        // movie timescale can round off the final audio sample.
        writer.movieTimeScale = movieScale
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!, .cacheIntermediates: false])
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary, &pool)
        guard poolStatus == kCVReturnSuccess, let pool else { throw VideoError.message("Could not allocate export frames.") }
        guard writer.startWriting(), reader.startReading() else { throw writer.error ?? reader.error ?? VideoError.message("Could not start export.") }
        writer.startSession(atSourceTime: .zero)
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        var finished = Set<Int>()
        while finished.count < inputs.count {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? VideoError.message("The video writer stopped.") }
            var advanced = false
            for index in inputs.indices where !finished.contains(index) && inputs[index].isReadyForMoreMediaData {
                try autoreleasepool {
                    guard let sample = outputs[index].copyNextSampleBuffer() else {
                        if reader.status == .failed { throw reader.error ?? VideoError.message("Video decoding failed.") }
                        inputs[index].markAsFinished(); finished.insert(index); advanced = true
                        return
                    }
                    let output: CMSampleBuffer
                    if index == 0 {
                        guard let source = CMSampleBufferGetImageBuffer(sample) else { throw VideoError.message("A source frame is missing.") }
                        var rendered: CVPixelBuffer?
                        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &rendered) == kCVReturnSuccess, let rendered else {
                            throw VideoError.message("Could not allocate an export frame.")
                        }
                        CVBufferPropagateAttachments(source, rendered)
                        let image = CIImage(cvPixelBuffer: source)
                        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        let oriented = image.transformed(by: imageTransform)
                        let corrected = SpatialRenderer.render(oriented, global: curve.value(at: time), field: curve.field(at: time))
                            .transformed(by: imageTransform.inverted())
                        context.render(corrected, to: rendered, bounds: image.extent, colorSpace: image.colorSpace)
                        var format: CMVideoFormatDescription?
                        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: rendered, formatDescriptionOut: &format) == noErr,
                              let format else { throw VideoError.message("Could not describe an export frame.") }
                        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample),
                                                        presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), decodeTimeStamp: .invalid)
                        // Some decoders omit duration; the final sample must end
                        // at the video track's end, not the audio/asset end.
                        if !timing.duration.isNumeric || timing.duration <= .zero {
                            timing.duration = CMTimeSubtract(timeRange.end, timing.presentationTimeStamp)
                        }
                        var buffer: CMSampleBuffer?
                        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: rendered,
                            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &buffer) == noErr, let buffer else {
                            throw VideoError.message("Could not preserve frame timing.")
                        }
                        output = buffer
                        progress(min(0.99, timing.presentationTimeStamp.seconds / max(0.001, timeRange.end.seconds)))
                    } else { output = sample }
                    guard inputs[index].append(output) else { throw writer.error ?? VideoError.message("Could not write an export sample.") }
                    advanced = true
                }
            }
            if !advanced { try await Task.sleep(for: .milliseconds(5)) }
        }
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? VideoError.message("The video export did not complete.") }
        progress(1)
    }
}

enum ExportTiming {
    static func commonTimescale(_ a: CMTimeScale, _ b: CMTimeScale) -> CMTimeScale {
        guard a > 0, b > 0 else { return max(1, max(a, b)) }
        var x = Int64(a), y = Int64(b)
        while y != 0 { let remainder = x % y; x = y; y = remainder }
        let scale = Int64(a) / x * Int64(b)
        return scale <= Int64(Int32.max) ? CMTimeScale(scale) : max(a, b)
    }
}
