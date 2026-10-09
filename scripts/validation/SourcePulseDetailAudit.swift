// Source-only, bounded rolling-window detail audit. Compile with the core sources.
// Usage: SourcePulseDetailAudit source startSeconds endSeconds width
// Width is 96 or 192. Supply a known SINGLE-SCENE half-open time range.
// FRANKLUMA_DETAIL_FRAME_INTERVAL=1...6 controls spacing of the three samples.
// This harness never estimates correction fields, renders output or exports.
import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

@main struct SourcePulseDetailAudit {
    private struct SourceFrame: Codable {
        let index: Int
        let time: Double
        let image: SpatialThumbnail
    }

    private struct TimingIndex {
        let precedingFrames: Int
        let timestamps: [CMTime]

        func frameIndex(at timestamp: CMTime) throws -> Int {
            var low = 0, high = timestamps.count
            while low < high {
                let middle = (low+high)/2
                if CMTimeCompare(timestamps[middle], timestamp) < 0 { low = middle+1 }
                else { high = middle }
            }
            guard low < timestamps.count, CMTimeCompare(timestamps[low], timestamp) == 0 else {
                throw VideoError.message("Decoded presentation timestamp was absent from the source timing index.")
            }
            return precedingFrames+low
        }
    }

    /// Count source frames using compressed sample timing, not nominal FPS.
    /// Retain only timestamps inside the requested range; no image is decoded
    /// in this pass. Sorting preserves presentation-frame numbering with B frames.
    private static func timingIndex(asset: AVAsset, track: AVAssetTrack, trackStart: CMTime,
                                    start: Double, end: Double) throws -> TimingIndex {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.message("Cannot read source sample timing.") }
        reader.add(output)
        let endTime = CMTime(seconds: end, preferredTimescale: 600_000_000)
        reader.timeRange = CMTimeRange(start: trackStart, duration: CMTimeSubtract(endTime, trackStart))
        guard reader.startReading() else { throw reader.error ?? VideoError.message("Cannot start source timing reader.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var preceding = 0, timestamps: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            for index in 0..<CMSampleBufferGetNumSamples(sample) {
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr,
                      timing.presentationTimeStamp.seconds.isFinite else {
                    throw VideoError.message("Source has invalid presentation timing.")
                }
                let time = timing.presentationTimeStamp.seconds
                if time < start { preceding += 1 }
                else if time < end { timestamps.append(timing.presentationTimeStamp) }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? VideoError.message("Source timing read did not complete.") }
        timestamps.sort { CMTimeCompare($0, $1) < 0 }
        guard zip(timestamps, timestamps.dropFirst()).allSatisfy({ CMTimeCompare($0, $1) < 0 }) else {
            throw VideoError.message("Duplicate source presentation timestamps cannot be assigned unique frame indices.")
        }
        return TimingIndex(precedingFrames: preceding, timestamps: timestamps)
    }

    private static func thumbnail(buffer: CVPixelBuffer, transform: CGAffineTransform,
                                  width: Int, height: Int, context: CIContext,
                                  linear: CGColorSpace) throws -> SpatialThumbnail {
        let frame = CIImage(cvPixelBuffer: buffer).transformed(by: transform)
        let extent = frame.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            throw VideoError.message("Invalid transformed source extent.")
        }
        // Production resolutions use the exact 192x112 Lanczos raster.
        // Larger dump-only rasters investigate reduction artifacts; they are
        // not geometry audits or a production-resolution change.
        // Production's 96x56 spatial data is its 2x2 box average, not a separate
        // direct-to-96 resize. Keeping this distinction makes the comparison fair.
        let detailWidth = max(192,width), detailHeight = max(192,width)*112/192
        let scale = Double(detailHeight)/extent.height
        let source = frame.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
        let image: CIImage
        if ProcessInfo.processInfo.environment["FRANKLUMA_DETAIL_ANALYSIS_PREFILTER"] == "1" {
            // Source-only ablation: Gaussian prefilter and B-spline reduction.
            // This changes analysis pixels/geometry and is not production parity.
            let radius = 0.5*max(extent.width/Double(detailWidth),extent.height/Double(detailHeight))
            let filtered = source.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:source.extent)
            let reduction = CIFilter.bicubicScaleTransform()
            reduction.inputImage = filtered;reduction.scale = Float(scale)
            reduction.aspectRatio = Float(Double(detailWidth)/extent.width/scale)
            reduction.parameterB = 1;reduction.parameterC = 0
            guard let output = reduction.outputImage else { throw VideoError.message("Cannot create analysis reduction.") }
            image = output
        } else {
            image = source.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale,
                kCIInputAspectRatioKey: Double(detailWidth)/extent.width/scale])
        }
        var rgba = [Float](repeating: 0, count: detailWidth*detailHeight*4)
        rgba.withUnsafeMutableBytes { bytes in
            context.render(image, toBitmap: bytes.baseAddress!, rowBytes: detailWidth*16,
                bounds: CGRect(x: 0, y: 0, width: detailWidth, height: detailHeight), format: .RGBAf, colorSpace: linear)
        }
        let block = detailWidth/width
        guard block*width == detailWidth, block*height == detailHeight else {
            throw VideoError.message("Audit thumbnail dimensions do not match the production aspect ratio.")
        }
        var rgb = [Float](repeating: 0, count: width*height*3)
        for y in 0..<height { for x in 0..<width { for channel in 0..<3 {
            var value: Float = 0
            for dy in 0..<block { for dx in 0..<block {
                value += rgba[((y*block+dy)*detailWidth+x*block+dx)*4+channel]/Float(block*block)
            } }
            rgb[(y*width+x)*3+channel] = value
        } } }
        return SpatialThumbnail(width: width, height: height, rgb: rgb)
    }

    private static func level(_ image: SpatialThumbnail, x: Int, y: Int) -> Double {
        var sum = 0.0
        for dy in -2...2 { for dx in -2...2 {
            let pixel = ((y+dy)*image.width+x+dx)*3
            sum += 0.2126*Double(image.rgb[pixel])+0.7152*Double(image.rgb[pixel+1])+0.0722*Double(image.rgb[pixel+2])
        } }
        return log2(max(1e-9, sum/25))
    }

    private static func emit(_ prefix: String, _ record: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else { throw VideoError.message("Cannot encode audit record.") }
        print(prefix, json)
    }

    private static func audit(_ frames: [SourceFrame], width: Int, height: Int,
                              rangeStart: Double, rangeEnd: Double) throws {
        let images = frames.map(\.image)
        let environment = ProcessInfo.processInfo.environment
        let geometryHalf = environment["FRANKLUMA_DETAIL_WIDE_MATCH"] == "1" ? 6 : 2
        let geometryOnly = environment["FRANKLUMA_DETAIL_GEOMETRY_ONLY"] == "1"
        let before = SurfaceTracking.Prepared(images[0],half: geometryHalf), middle = SurfaceTracking.Prepared(images[1],half: geometryHalf)
        let after = SurfaceTracking.Prepared(images[2],half: geometryHalf)
        let proposedStride = Int(environment["FRANKLUMA_DETAIL_SEED_STRIDE"] ?? "6") ?? 6
        let step = max(3,min(12,proposedStride))*width/96, radius = 8*width/96, margin = 7*width/96
        var tracks: [TrackedSurfaceResidual.Track] = []
        var rejections: [String: Int] = [:], seeds = 0, identitySeeds = 0
        // Keep the seed-grid phase approximately fixed in displayed source
        // coordinates when comparing resolutions; identity remains half=2.
        for y in stride(from: margin, to: height-margin, by: step) {
            for x in stride(from: margin, to: width-margin, by: step) {
                seeds += 1
                guard let identity = PersistentSurfaceIdentity.descriptor(images[1], x: Double(x), y: Double(y), half: geometryHalf) else {
                    rejections["middleNoIdentity", default: 0] += 1; continue
                }
                identitySeeds += 1
                guard let a = SurfaceTracking.match(middle, before, x: x, y: y, radius: radius, subpixel: false) else {
                    rejections["beforeNoReciprocalMatch", default: 0] += 1; continue
                }
                guard a.confidence*(geometryOnly ? 1 : a.photometricConfidence) > 0.6 else {
                    rejections["beforeWeakConfidence", default: 0] += 1; continue
                }
                guard let c = SurfaceTracking.match(middle, after, x: x, y: y, radius: radius, subpixel: false) else {
                    rejections["afterNoReciprocalMatch", default: 0] += 1; continue
                }
                guard c.confidence*(geometryOnly ? 1 : c.photometricConfidence) > 0.6 else {
                    rejections["afterWeakConfidence", default: 0] += 1; continue
                }
                guard let identityA = PersistentSurfaceIdentity.descriptor(images[0], x: Double(a.x), y: Double(a.y), half: geometryHalf),
                      PersistentSurfaceIdentity.agrees(identity, identityA) else {
                    rejections["beforeIdentityMismatch", default: 0] += 1; continue
                }
                guard let identityC = PersistentSurfaceIdentity.descriptor(images[2], x: Double(c.x), y: Double(c.y), half: geometryHalf),
                      PersistentSurfaceIdentity.agrees(identity, identityC) else {
                    rejections["afterIdentityMismatch", default: 0] += 1; continue
                }
                tracks.append(.init(identity: identity, identityHalf: geometryHalf, observations: [
                    .init(frame: 0, x: a.x, y: a.y, level: level(images[0], x: a.x, y: a.y)),
                    .init(frame: 1, x: x, y: y, level: level(images[1], x: x, y: y)),
                    .init(frame: 2, x: c.x, y: c.y, level: level(images[2], x: c.x, y: c.y))]))
            }
        }
        let cameraGuided = environment["FRANKLUMA_DETAIL_CAMERA_GUIDED"] == "1"
        let cameraHalf = environment["FRANKLUMA_DETAIL_SCALE_CAMERA_SUPPORT"] == "1" ? 6*width/96 : 6
        var cameraEvidence: [String: Any] = [:]
        if cameraGuided {
            let coarse = images.map(SurfaceMotion.coarse)
            let models = [SurfaceMotion.estimate(coarse[1],coarse[0]),SurfaceMotion.estimate(coarse[1],coarse[2])]
            var candidates: [TrackedSurfaceResidual.Track] = []
            var eligible = [0,0],stationary = [[(Int,Int)]](repeating:[],count:2)
            for y in stride(from:margin,to:height-margin,by:step) {
                for x in stride(from:margin,to:width-margin,by:step) {
                    guard SurfaceTracking.cameraShapeCorrelation(images[1],images[1],x:x,y:y,referenceX:x,referenceY:y,half:cameraHalf) != nil else { continue }
                    var points = [(Int,Int)](), valid = true
                    for (j,index) in [0,2].enumerated() {
                        let q = models[j]?.point(Double(x),Double(y)) ?? (Double(x),Double(y))
                        let px = Int(q.0.rounded()),py = Int(q.1.rounded())
                        guard let correlation = SurfaceTracking.cameraShapeCorrelation(images[1],images[index],x:x,y:y,referenceX:px,referenceY:py,half:cameraHalf) else { valid=false;continue }
                        eligible[j] += 1
                        guard correlation > 0.95 else { valid=false;continue }
                        if models[j] == nil { stationary[j].append((x,y)) }
                        points.append((px,py))
                    }
                    guard valid,points.count == 2,
                          let identity = PersistentSurfaceIdentity.descriptor(images[1],x:Double(x),y:Double(y),half:cameraHalf) else { continue }
                    candidates.append(.init(identity:identity,identityHalf:cameraHalf,observations:[
                        .init(frame:0,x:points[0].0,y:points[0].1,level:level(images[0],x:points[0].0,y:points[0].1)),
                        .init(frame:1,x:x,y:y,level:level(images[1],x:x,y:y)),
                        .init(frame:2,x:points[1].0,y:points[1].1,level:level(images[2],x:points[1].0,y:points[1].1))]))
                }
            }
            func stationarySupported(_ j: Int) -> Bool {
                let points = stationary[j]
                guard points.count >= max(12,Int(ceil(0.6*Double(eligible[j])))) else { return false }
                return points.map({ $0.0 }).max()!-points.map({ $0.0 }).min()! >= width/2 &&
                       points.map({ $0.1 }).max()!-points.map({ $0.1 }).min()! >= height/2
            }
            let supported = (0..<2).allSatisfy { models[$0] != nil || stationarySupported($0) }
            cameraEvidence = ["movingModels":models.map { $0 != nil },"stationaryAnchors":stationary.map(\.count),
                "eligibleAnchors":eligible,"geometrySupported":supported,"candidates":candidates.count]
            tracks = supported ? candidates : []
        }
        try emit("SOURCE_DETAIL_FRAME", ["frame": frames[1].index, "time": frames[1].time,
            "beforeFrame": frames[0].index, "afterFrame": frames[2].index,
            "beforeTime": frames[0].time, "afterTime": frames[2].time,
            "rangeStart": rangeStart, "rangeEnd": rangeEnd, "width": width, "height": height,
            "stride": step, "margin": margin, "radius": radius, "endpointRadius": 2*radius,
            "geometryHalf":geometryHalf,"geometryOnly":geometryOnly,"cameraGuided":cameraGuided,"cameraHalf":cameraHalf,"cameraEvidence":cameraEvidence,"seeds": seeds, "identitySeeds": identitySeeds, "triples": tracks.count, "rejections": rejections,
            "frameIndexMethod": "compressedSourcePresentationOrder", "singleSceneRangeRequired": true])
        let samples = frames.map { ExposureSample(time: $0.time, level: 0, segment: 0, thumbnail: $0.image) }
        if tracks.isEmpty {
            // The core routine has no entry to emit when there are no triples.
            // Make that absence explicit rather than silently omitting a frame.
            let environment = ProcessInfo.processInfo.environment
            let proposedTolerance = Double(environment["FRANKLUMA_COMMON_PULSE_TOLERANCE"] ?? "0.02") ?? 0.02
            let tolerance = proposedTolerance.isFinite && (0.005...0.1).contains(proposedTolerance) ? proposedTolerance : 0.02
            let proposedDonors = Int(environment["FRANKLUMA_COMMON_PULSE_DONORS"] ?? "12") ?? 12
            let minimumDonors = (4...48).contains(proposedDonors) ? proposedDonors : 12
            try emit("COMMON_LIGHT_SOURCE_PULSE", ["sceneStart": frames[0].time, "middleFrame": 1,
                "endpointRadius": 2*radius, "triples": 0, "pixelQualified": 0,
                "tolerance": tolerance, "minimumDonors": minimumDonors,
                "luminanceOnly": environment["FRANKLUMA_COMMON_PULSE_LUMINANCE"] == "1",
                "eventQueries": 0, "absenceQueries": 0, "responseQueries": 0,
                "maximumIndependentDonors13": 0, "hypotheticalMaximumDonors5": 0,
                "medianEndpointError": 0, "medianMatcherEnergy": 0,
                "rejections": ["detailHarnessNoTriples": 1], "eventPoints": []])
        } else {
            TrackedSurfaceResidual.pulseDiagnostics(samples: samples, images: images, tracks: tracks, endpointRadius: 2*radius, geometryHalf: geometryHalf, geometryOnly: geometryOnly, cameraGuided:cameraGuided,cameraHalf:cameraHalf,photometryHalf:Int(environment["FRANKLUMA_DETAIL_PHOTOMETRY_HALF"] ?? "2") ?? 2)
        }
    }

    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, let start = Double(arguments[2]), let requestedEnd = Double(arguments[3]),
              let width = Int(arguments[4]), [96, 192, 384, 768].contains(width),
              start.isFinite, requestedEnd.isFinite, start >= 0, requestedEnd > start else {
            throw VideoError.message("Usage: SourcePulseDetailAudit source startSeconds endSeconds width(96|192|384|768). Higher resolutions require dump-only mode. Supply one known scene range; end is exclusive.")
        }
        let environment = ProcessInfo.processInfo.environment
        let dumpDirectory = environment["FRANKLUMA_DETAIL_DUMP_DIRECTORY"].map { URL(fileURLWithPath:$0,isDirectory:true) }
        let dumpOnly = environment["FRANKLUMA_DETAIL_DUMP_ONLY"] == "1"
        guard width <= 192 || dumpOnly else { throw VideoError.message("Higher-resolution diagnostic rasters are dump-only; geometry thresholds are defined for production sizes.") }
        let intervalText = environment["FRANKLUMA_DETAIL_FRAME_INTERVAL"] ?? "1"
        guard let interval = Int(intervalText),(1...6).contains(interval) else {
            throw VideoError.message("Detail frame interval must be 1–6.")
        }
        let windowCount = dumpOnly ? 3 : 2*interval+1
        guard !dumpOnly || dumpDirectory != nil else { throw VideoError.message("Dump-only mode requires a diagnostic output directory.") }
        if let directory = dumpDirectory {
            guard !FileManager.default.fileExists(atPath:directory.path) else { throw VideoError.message("Refusing to overwrite diagnostic frames.") }
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        }
        let source: URL
        if arguments[1].hasPrefix("file://") {
            guard let url = URL(string: arguments[1]), url.isFileURL else { throw VideoError.message("Invalid source file URL.") }
            source = url
        } else { source = URL(fileURLWithPath: arguments[1]) }
        let asset = AVURLAsset(url: source)
        try MediaSupport.validate(try await VideoEngine.info(for: asset))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.message("No source video track.") }
        let preferred = try await track.load(.preferredTransform)
        let naturalSize = try await track.load(.naturalSize)
        let trackRange = try await track.load(.timeRange)
        let end = min(requestedEnd, trackRange.end.seconds)
        guard end.isFinite, end > start else { throw VideoError.message("Requested range has no source video.") }
        let timing = try timingIndex(asset: asset, track: track, trackStart: trackRange.start, start: start, end: end)
        guard timing.timestamps.count >= windowCount else { throw VideoError.message("Requested range contains too few video frames for the requested interval.") }
        let transform = VideoGeometry.coreImageTransform(preferred: preferred, naturalSize: naturalSize)
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linear, .cacheIntermediates: false])
        let height = Int((Double(width)*56/96).rounded())
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.message("Cannot decode source frames.") }
        reader.add(output)
        let startTime = CMTime(seconds: start, preferredTimescale: 600_000_000)
        let endTime = CMTime(seconds: end, preferredTimescale: 600_000_000)
        reader.timeRange = CMTimeRange(start: startTime, duration: CMTimeSubtract(endTime, startTime))
        guard reader.startReading() else { throw reader.error ?? VideoError.message("Cannot start source range decoder.") }
        defer { if reader.status == .reading { reader.cancelReading() } }
        var window: [SourceFrame] = [], decoded = 0, audited = 0
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            try autoreleasepool {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample), time = pts.seconds
                guard time.isFinite else { throw VideoError.message("Invalid decoded source timestamp.") }
                guard time >= start, time < end else { return }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw VideoError.message("Missing decoded source pixels.") }
                let index = try timing.frameIndex(at: pts)
                if let last = window.last, index != last.index+1 || time <= last.time {
                    throw VideoError.message("Decoded source range is not consecutive in presentation order.")
                }
                // Bounded rolling source window; interval one retains three
                // thumbnails, wider audits retain at most thirteen.
                if window.count == windowCount { window.removeFirst() }
                let image = try thumbnail(buffer: buffer, transform: transform, width: width, height: height, context: context, linear: linear)
                let sourceFrame = SourceFrame(index:index,time:time,image:image)
                if let directory = dumpDirectory {
                    try JSONEncoder().encode(sourceFrame).write(to:directory.appendingPathComponent("frame-\(index).json"),options:.atomic)
                }
                window.append(sourceFrame)
                decoded += 1
                if window.count == windowCount && !dumpOnly {
                    try audit([window[0],window[interval],window[2*interval]], width: width, height: height, rangeStart: start, rangeEnd: end)
                    audited += 1
                }
            }
        }
        guard reader.status == .completed else { throw reader.error ?? VideoError.message("Source range decoding did not complete.") }
        guard decoded == timing.timestamps.count else { throw VideoError.message("Compressed and decoded source frame counts disagree.") }
        try emit("SOURCE_DETAIL_COMPLETE", ["source": source.path, "start": start, "end": end,
            "width": width, "height": height, "decodedFrames": decoded, "auditedMiddleFrames": audited,
            "analysisReduction":environment["FRANKLUMA_DETAIL_ANALYSIS_PREFILTER"] == "1" ? "gaussianBsplineExperimental" : (width > 192 ? "higherResolutionLanczosDiagnostic" : "productionLanczos"),"frameInterval":interval,"peakRetainedSourceThumbnails": min(windowCount, decoded),"dumpedFrames":dumpDirectory == nil ? 0 : decoded,"dumpOnly":dumpOnly, "correctionOrExport": false])
    }
}
