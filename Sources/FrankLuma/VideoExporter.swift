import AVFoundation
import CoreImage
import AudioToolbox

enum ExportFormat: String, CaseIterable, Sendable, Codable {
    case h264MP4, h264MOV, hevcMP4, hevcMOV, proResMOV

    var title: String {
        switch self {
        case .h264MP4: return "MP4 — H.264 (Sharing)"
        case .h264MOV: return "QuickTime — H.264"
        case .hevcMP4: return "MP4 — HEVC (Smaller files)"
        case .hevcMOV: return "QuickTime — HEVC"
        case .proResMOV: return "QuickTime — ProRes 422 (Editing)"
        }
    }
    var fileType: AVFileType { isMP4 ? .mp4 : .mov }
    var isMP4: Bool { self == .h264MP4 || self == .hevcMP4 }
    var fileExtension: String { isMP4 ? "mp4" : "mov" }
    var codec: AVVideoCodecType {
        switch self {
        case .h264MP4, .h264MOV: return .h264
        case .hevcMP4, .hevcMOV: return .hevc
        case .proResMOV: return .proRes422
        }
    }
}

enum ExportQuality: String, CaseIterable, Sendable, Codable {
    case standard = "Standard", high = "High"
    var bitrateFactor: Double { self == .high ? 0.16 : 0.08 }
}

struct VideoExportOptions: Sendable, Codable, Equatable {
    var format: ExportFormat = .h264MOV
    var quality: ExportQuality = .high

    func videoSettings(size: CGSize, fps: Float, sourceRate: Float) -> [String: Any] {
        var settings: [String: Any] = [AVVideoCodecKey: format.codec,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)]
        if format != .proResMOV {
            let efficiency = format.codec == .hevc ? 0.65 : 1.0
            let sourceMultiplier = quality == .high ? 1.5 : 0.75
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: max(Double(sourceRate) * sourceMultiplier,
                    size.width * size.height * Double(max(1, fps)) * quality.bitrateFactor) * efficiency,
                AVVideoAllowFrameReorderingKey: false
            ]
        }
        return settings
    }

    func convertsAudio(_ formats: [CMFormatDescription]) -> Bool {
        // AAC is portable in MP4. Keep all QuickTime audio and existing AAC
        // compressed samples unchanged; convert other MP4 audio to AAC.
        format.isMP4 && (formats.isEmpty || formats.contains { CMFormatDescriptionGetMediaSubType($0) != kAudioFormatMPEG4AAC })
    }
}

/// Writes one output sample per decoded source sample, retaining its timestamp
/// and duration. Audio is preserved or converted independently, including a longer tail.
enum VideoExporter {
    static func export(asset: AVAsset, curve: ExposureCurve, destination: URL, options: VideoExportOptions = .init(),
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
        let writer = try AVAssetWriter(outputURL: destination, fileType: options.format.fileType)
        writer.metadata = try await asset.load(.metadata)
        var movieScale = try await track.load(.naturalTimeScale)
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: options.format == .proResMOV ? kCVPixelFormatType_422YpCbCr10 : kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw VideoError.message("This video format cannot be decoded. Try exporting an SDR H.264 copy first.") }
        reader.add(videoOutput)
        var settings = options.videoSettings(size: size, fps: fps, sourceRate: rate)
        if options.format != .proResMOV, let format = formats.first, let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] {
            var colour: [String: Any] = [:]
            for (source, target) in [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimariesKey),
                                     (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunctionKey),
                                     (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrixKey)] {
                if let value = extensions[source as String] { colour[target] = value }
            }
            if !colour.isEmpty { settings[AVVideoColorPropertiesKey] = colour }
        }
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw VideoError.message("This video's dimensions or colour settings cannot be exported as \(options.format.title). Try an SDR Rec. 709 copy with standard video dimensions.")
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
            let convert = options.convertsAudio(audioFormats)
            let description = audioFormats.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            // Explicit stereo downmix for multichannel sources on MP4 conversion.
            let channels = min(2, max(1, Int(description?.mChannelsPerFrame ?? 2)))
            let sampleRate = description?.mSampleRate == 44100 ? 44100.0 : 48000.0
            let decodeSettings: [String: Any]? = convert ? [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ] : nil
            let encodeSettings: [String: Any]? = convert ? [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels * 128000
            ] : nil
            if let encodeSettings, !writer.canApply(outputSettings: encodeSettings, forMediaType: .audio) {
                throw VideoError.message("This audio track cannot be converted to AAC. Choose QuickTime to preserve original audio.")
            }
            let output = AVAssetReaderTrackOutput(track: audio, outputSettings: decodeSettings)
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encodeSettings,
                                          sourceFormatHint: convert ? nil : audioFormats.first)
            movieScale = ExportTiming.commonTimescale(movieScale, convert ? CMTimeScale(sampleRate) : audioScale)
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw VideoError.message("An audio track cannot be exported in this format. Choose QuickTime to preserve original audio.")
            }
            reader.add(output); writer.add(input)
            outputs.append(output); inputs.append(input)
        }
        // Keep edit-list ends exact as well as sample timestamps. The default
        // movie timescale can round off the final audio sample.
        writer.movieTimeScale = movieScale
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!, .workingFormat: CIFormat.RGBAh.rawValue, .cacheIntermediates: false])
        var pool: CVPixelBufferPool?
        let poolStatus = CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: options.format == .proResMOV ? kCVPixelFormatType_64ARGB : kCVPixelFormatType_32BGRA,
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
                        if options.format == .proResMOV {
                            try renderHighPrecision(corrected, to: rendered, context: context,
                                                    colorSpace: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!)
                        } else {
                            context.render(corrected, to: rendered, bounds: image.extent, colorSpace: image.colorSpace)
                        }
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

    /// Render 16-bit RGB and pack Core Video's big-endian ARGB64 format.
    /// This avoids an 8-bit intermediate before ProRes 422 encoding.
    static func renderHighPrecision(_ image: CIImage, to buffer: CVPixelBuffer,
                                    context: CIContext, colorSpace: CGColorSpace) throws {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var rgba = [UInt16](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: width * 8,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA16, colorSpace: colorSpace)
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            throw VideoError.message("Could not access a high-precision export frame.")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw VideoError.message("A high-precision export frame is missing.")
        }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
            for x in 0..<width {
                let source = (y * width + x) * 4, target = x * 4
                row[target] = rgba[source + 3].bigEndian
                row[target + 1] = rgba[source].bigEndian
                row[target + 2] = rgba[source + 1].bigEndian
                row[target + 3] = rgba[source + 2].bigEndian
            }
        }
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
