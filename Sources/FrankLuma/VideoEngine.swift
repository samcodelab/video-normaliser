import AVFoundation
import CoreImage
import AppKit

struct VideoInfo: Sendable {
    let duration: Double
    let width: Int
    let height: Int
    let fps: Double
    let hasAudio: Bool
    let isHDR: Bool
}

struct AnalysisResult: Sendable {
    let samples: [ExposureSample]
    let uncertainFrames: Int
    let cuts: Int
}

enum VideoError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum VideoEngine {
    static func preview(url: URL, time: Double, curve: ExposureCurve, comparisonSize: CGSize? = nil, diagnostic: PreviewMode = .corrected, frameEnd: Double? = nil) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 1000)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        // Decode the source pose before applying correction. A composition's
        // rendering cadence can otherwise round a still request to the prior
        // frame, even when the timeline has selected an exact source timestamp.
        let end = frameEnd ?? curve.times.first(where: { $0 > time + 0.000001 })
        let requestTime = PreviewTiming.interiorTime(start: time, end: end)
        let decoded = try await generator.image(at: CMTime(seconds: requestTime, preferredTimescale: 6000000))
        let frame = decoded.image
        guard !curve.times.isEmpty || comparisonSize != nil else { return frame }
        let source = CIImage(cgImage: frame)
        // Always associate the gain with the decoded source sample. This also
        // prevents a bright flash if an image generator returns an earlier pose.
        let sourceTime = decoded.actualTime.seconds
        var output = SpatialRenderer.render(source, global: curve.value(at: sourceTime),
                                            field: curve.field(at: sourceTime), diagnostic: diagnostic)
        if comparisonSize != nil {
            output = output.transformed(by: CGAffineTransform(translationX: source.extent.width, y: 0))
                .composited(over: source)
                .cropped(to: CGRect(x: 0, y: 0, width: source.extent.width * 2, height: source.extent.height))
        }
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!, .cacheIntermediates: false])
        guard let image = context.createCGImage(output, from: output.extent) else {
            throw VideoError.message("Could not render the selected frame.")
        }
        return image
    }

    static func liveComposition(asset: AVAsset, state: PreviewCorrection, comparisonSize: CGSize? = nil, diagnostic: PreviewMode = .corrected) -> AVVideoComposition {
        let composition = AVMutableVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let correction = state.snapshot()
            let stops = correction.value(at: request.compositionTime.seconds)
            let source = comparisonSize.map { request.sourceImage.cropped(to: CGRect(origin: .zero, size: $0)) } ?? request.sourceImage
            var output = SpatialRenderer.render(source, global: stops, field: correction.field(at: request.compositionTime.seconds), diagnostic: diagnostic)
            if let comparisonSize {
                output = output.transformed(by: CGAffineTransform(translationX: comparisonSize.width, y: 0))
                    .composited(over: source)
                    .cropped(to: CGRect(x: 0, y: 0, width: comparisonSize.width * 2, height: comparisonSize.height))
            }
            request.finish(with: output, context: nil)
        })
        if let comparisonSize { composition.renderSize = CGSize(width: comparisonSize.width * 2, height: comparisonSize.height) }
        return composition
    }
    static func info(for asset: AVAsset) async throws -> VideoInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoError.message("This file has no readable video track.")
        }
        guard try await !asset.load(.hasProtectedContent) else {
            throw VideoError.message("Protected videos cannot be processed. Choose an unprotected SDR video.")
        }
        let duration = try await track.load(.timeRange).end.seconds
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let display = CGRect(origin: .zero, size: size).applying(transform)
        guard abs(display.width) >= 1, abs(display.height) >= 1 else { throw VideoError.message("The video has invalid image dimensions.") }
        let fps = try await track.load(.nominalFrameRate)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let formats = try await track.load(.formatDescriptions)
        let hdr = formats.contains { format in
            guard let rawExtensions = CMFormatDescriptionGetExtensions(format) else { return false }
            let extensions = rawExtensions as NSDictionary
            let transfer = extensions[kCMFormatDescriptionExtension_TransferFunction] as? String ?? ""
            return MediaSupport.isHDRTransfer(transfer)
        }
        guard duration.isFinite, duration > 0 else { throw VideoError.message("The video has no playable duration.") }
        return VideoInfo(duration: duration, width: Int(abs(display.width)), height: Int(abs(display.height)), fps: Double(fps), hasAudio: !audio.isEmpty, isHDR: hdr)
    }

    static func analyse(url: URL, region: CGRect?, progress: @escaping @Sendable (Double) -> Void) async throws -> AnalysisResult {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.message("No video track found.") }
        try MediaSupport.validate(try await info(for: asset))
        let duration = try await asset.load(.duration).seconds
        let preferred = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let transform = VideoGeometry.coreImageTransform(preferred: preferred, naturalSize: naturalSize)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.message("This video format cannot be decoded.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoError.message("Could not start reading the video.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
        let width = 48, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var samples: [ExposureSample] = []
        var appearances: [(index: Int, frame: FrameAppearance)] = []
        var detectedBoundaries: Set<Int> = []
        func checkBoundary(_ index: Int) {
            guard index > 0,
                  let previous = appearances.first(where: { $0.index == index-1 })?.frame,
                  let current = appearances.first(where: { $0.index == index })?.frame else { return }
            let preceding = appearances.first(where: { $0.index == index-2 })?.frame
            let following = appearances.filter { $0.index > index }.prefix(3).map(\.frame)
            if SceneDetection.isCut(preceding: preceding, previous: previous, current: current, following: following) {
                detectedBoundaries.insert(index)
            }
        }
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { throw VideoError.message("A video frame could not be decoded.") }
                let frame = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: transform)
                let extent = frame.extent
                func appearance(in crop: CGRect) -> FrameAppearance {
                    var thumbnail = frame.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                    thumbnail = thumbnail.transformed(by: CGAffineTransform(scaleX: Double(width) / crop.width, y: Double(height) / crop.height))
                    pixels.withUnsafeMutableBytes { bytes in
                        context.render(thumbnail, toBitmap: bytes.baseAddress!, rowBytes: width * 4,
                                       bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBA8, colorSpace: linear)
                    }
                    return FrameAppearance(pixels: pixels, width: width, height: height)
                }
                let wholeFrame = appearance(in: extent)
                let r = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                let crop = CGRect(x: extent.minX + r.minX * extent.width,
                                  y: extent.minY + (1 - r.maxY) * extent.height,
                                  width: r.width * extent.width, height: r.height * extent.height)
                // Filter before reducing resolution. The old 48×32 point sample
                // was sensitive to subpixel subject motion and quantised darks.
                let patchWidth = 192, patchHeight = 112, block = 8
                let scale = Double(patchHeight) / crop.height
                let thumbnail = frame.cropped(to: crop)
                    .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
                    .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale,
                        kCIInputAspectRatioKey: Double(patchWidth) / crop.width / scale])
                var floatPixels = [Float](repeating: 0, count: patchWidth * patchHeight * 4)
                floatPixels.withUnsafeMutableBytes { bytes in
                    context.render(thumbnail, toBitmap: bytes.baseAddress!, rowBytes: patchWidth * 16,
                                   bounds: CGRect(x: 0, y: 0, width: patchWidth, height: patchHeight), format: .RGBAf, colorSpace: linear)
                }
                var patches = [Double](repeating: 0, count: (patchWidth / block) * (patchHeight / block))
                for y in 0..<patchHeight { for x in 0..<patchWidth {
                    let p = (y * patchWidth + x) * 4
                    patches[(y / block) * (patchWidth / block) + x / block] +=
                        (0.2126 * Double(floatPixels[p]) + 0.7152 * Double(floatPixels[p + 1]) + 0.0722 * Double(floatPixels[p + 2])) / Double(block * block)
                } }
                // Keep a full-frame RGB thumbnail for motion registration and
                // spatial residuals, even when global exposure uses a manual ROI.
                if region != nil {
                    let full = frame.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: Double(patchHeight)/extent.height,
                            kCIInputAspectRatioKey: Double(patchWidth)/extent.width/(Double(patchHeight)/extent.height)])
                    floatPixels.withUnsafeMutableBytes { bytes in
                        context.render(full, toBitmap: bytes.baseAddress!, rowBytes: patchWidth * 16,
                                       bounds: CGRect(x: 0, y: 0, width: patchWidth, height: patchHeight), format: .RGBAf, colorSpace: linear)
                    }
                }
                var rgb = [Float](repeating: 0, count: 96*56*3)
                for y in 0..<56 { for x in 0..<96 { for channel in 0..<3 {
                    var value: Float = 0
                    for dy in 0..<2 { for dx in 0..<2 { value += floatPixels[((y*2+dy)*patchWidth+x*2+dx)*4+channel] / 4 } }
                    rgb[(y*96+x)*3+channel] = value
                } } }
                let spatialThumbnail = SpatialThumbnail(width: 96, height: 56, rgb: rgb)
                let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                samples.append(ExposureSample(time: time, level: 0, segment: 0, cells: patches, thumbnail: spatialThumbnail))
                // Three frames of lookahead distinguish a lasting foreground
                // replacement from short lighting flashes. Retain six descriptors.
                appearances.append((samples.count - 1, wholeFrame))
                if appearances.count > 6 { appearances.removeFirst() }
                checkBoundary(samples.count - 4)
                if samples.count.isMultiple(of: 12) { progress(min(1, time / duration)) }
            }
        }
        try Task.checkCancellation()
        if reader.status == .failed { throw reader.error ?? VideoError.message("Video decoding failed.") }
        guard samples.count > 1 else { throw VideoError.message("At least two video frames are needed for analysis.") }
        checkBoundary(samples.count - 3)
        checkBoundary(samples.count - 2)
        checkBoundary(samples.count - 1)
        samples = SceneMath.assign(samples, boundaries: detectedBoundaries)
        progress(1)
        var measured: [ExposureSample] = []
        var uncertain = 0
        for scene in SceneMath.scenes(samples: samples, boundaries: SceneMath.boundaries(in: samples), duration: duration) {
            let frames = Array(samples[scene.startFrame..<(scene.startFrame + scene.frameCount)])
            let patches = PatchExposure(cells: frames.map(\.cells))
            if !patches.reliable { uncertain += frames.count }
            measured += frames.enumerated().map { index, sample in
                ExposureSample(time: sample.time, level: patches.levels[index], segment: sample.segment, cells: sample.cells, thumbnail: sample.thumbnail)
            }
        }
        return AnalysisResult(samples: measured, uncertainFrames: uncertain, cuts: detectedBoundaries.count)
    }

    static func composition(asset: AVAsset, curve: ExposureCurve, diagnostic: PreviewMode = .corrected) -> AVVideoComposition {
        AVVideoComposition(asset: asset, applyingCIFiltersWithHandler: { request in
            let stops = curve.value(at: request.compositionTime.seconds)
            let output = SpatialRenderer.render(request.sourceImage, global: stops, field: curve.field(at: request.compositionTime.seconds), diagnostic: diagnostic)
            request.finish(with: output, context: nil)
        })
    }

    static func export(asset: AVAsset, curve: ExposureCurve, destination: URL, options: VideoExportOptions = .init(),
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        try await VideoExporter.export(asset: asset, curve: curve, destination: destination, options: options, progress: progress)
    }
}

/// The player keeps one composition instead of replacing it on every slider
/// change. AVFoundation invokes its filter on background rendering threads.
final class PreviewCorrection: @unchecked Sendable {
    private let lock = NSLock()
    private var curve = ExposureCurve.empty
    func set(_ value: ExposureCurve) { lock.lock(); curve = value; lock.unlock() }
    func snapshot() -> ExposureCurve { lock.lock(); defer { lock.unlock() }; return curve }
    func value(at time: Double) -> Double {
        lock.lock(); defer { lock.unlock() }
        return curve.value(at: time)
    }
}


enum MediaSupport {
    static func isHDRTransfer(_ transfer: String) -> Bool {
        transfer.contains("2084") || transfer.contains("2100") || transfer.uppercased().contains("HLG") || transfer.uppercased() == "PQ"
    }
    static func validate(_ info: VideoInfo) throws {
        if info.isHDR {
            throw VideoError.message("HDR video is not supported in FrankLuma 1.0. Export an SDR (Rec. 709) copy from your video editor, then open that copy. Your original has not been changed.")
        }
        guard info.width <= 4096, info.height <= 4096 else {
            throw VideoError.message("FrankLuma 1.0 supports SDR videos up to 4096 pixels on either side. Export a smaller SDR copy first.")
        }
    }
    static func exportFailure(_ error: Error) -> String {
        let e = error as NSError
        if (e.domain == NSCocoaErrorDomain && e.code == NSFileWriteOutOfSpaceError) ||
           (e.domain == NSPOSIXErrorDomain && e.code == 28) {
            return "The destination ran out of storage. Free some space or choose another drive, then export again. An existing destination was not replaced."
        }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? Error {
            return exportFailure(underlying)
        }
        return "Export failed: \(error.localizedDescription)\nChoose a writable destination with enough free space and try again. An existing destination was not replaced."
    }
}
