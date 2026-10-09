// Isolate correction before/after downsampling without an output codec.
import Foundation
import AVFoundation
import CoreImage

@main struct FullResolutionPredictionAudit {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 6, let first = Int(args[4]), first >= 0 else {
            throw VideoError.message("Usage: source before-diagnostics after-diagnostics first-frame report.json")
        }
        let source = URL(fileURLWithPath: args[1])
        let decoder = JSONDecoder()
        let folders = [args[2], args[3]].map { URL(fileURLWithPath: $0) }
        let fields = try folders.map { try decoder.decode([SpatialField].self, from: Data(contentsOf: $0.appendingPathComponent("spatial-fields.json"))) }
        let stops = try folders.map { try decoder.decode([Double].self, from: Data(contentsOf: $0.appendingPathComponent("global-stops.json"))) }
        guard fields.allSatisfy({ $0.indices.contains(first+1) }), stops.allSatisfy({ $0.indices.contains(first+1) }) else {
            throw VideoError.message("Frame outside diagnostics")
        }
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw VideoError.message("No video track") }
        let preferred = try await track.load(.preferredTransform)
        let size = try await track.load(.naturalSize)
        let transform = VideoGeometry.coreImageTransform(preferred: preferred, naturalSize: size)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw VideoError.message("Cannot decode source") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? VideoError.message("Reader failed") }
        defer { reader.cancelReading() }
        let linear = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAh.rawValue, .cacheIntermediates: false])
        func thumbnail(_ frame: CIImage) -> SpatialThumbnail {
            let extent = frame.extent
            let reduced = frame.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 112/extent.height,
                    kCIInputAspectRatioKey: (192/extent.width)/(112/extent.height)])
            var rgba = [Float](repeating: 0, count: 192*112*4)
            rgba.withUnsafeMutableBytes { bytes in
                context.render(reduced, toBitmap: bytes.baseAddress!, rowBytes: 192*16,
                               bounds: CGRect(x: 0,y: 0,width: 192,height: 112),format: .RGBAf,colorSpace: linear)
            }
            var rgb = [Float](repeating: 0,count: 96*56*3)
            for y in 0..<56 { for x in 0..<96 { for c in 0..<3 {
                for dy in 0..<2 { for dx in 0..<2 { rgb[(y*96+x)*3+c] += rgba[((y*2+dy)*192+x*2+dx)*4+c]/4 } }
            } } }
            return SpatialThumbnail(width: 96,height: 56,rgb: rgb)
        }
        var thumbnails: [[SpatialThumbnail]] = [[],[],[]]
        var quantized: [[SpatialThumbnail]] = [[],[]]
        var times: [Double] = []
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            if index == first || index == first+1 {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw VideoError.message("No frame pixels") }
                try autoreleasepool {
                    let original = CIImage(cvPixelBuffer: buffer)
                    let frame = original.transformed(by: transform)
                    thumbnails[0].append(thumbnail(frame))
                    for side in 0..<2 {
                        let corrected = SpatialRenderer.render(frame,global: stops[side][index],field: fields[side][index],diagnostic: .corrected)
                        thumbnails[side+1].append(thumbnail(corrected))
                        // Match the export's BGRA buffer and propagated colour
                        // attachments, but omit the lossy video encoder.
                        var destination: CVPixelBuffer?
                        let status = CVPixelBufferCreate(nil,CVPixelBufferGetWidth(buffer),CVPixelBufferGetHeight(buffer),
                            kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,&destination)
                        guard status == kCVReturnSuccess, let destination else { throw VideoError.message("Cannot allocate export-format pixels") }
                        CVBufferPropagateAttachments(buffer,destination)
                        context.render(corrected.transformed(by: transform.inverted()),to: destination,bounds: original.extent,colorSpace: original.colorSpace)
                        quantized[side].append(thumbnail(CIImage(cvPixelBuffer: destination).transformed(by: transform)))
                    }
                    times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                }
            }
            if index == first+1 { break }
            index += 1
        }
        guard times.count == 2 else { throw reader.error ?? VideoError.message("Selected frames not decoded") }
        struct Report: Codable {
            var source: String
            var frames: [Int]
            var times: [Double]
            var sourceThumbnails: [SpatialThumbnail]
            var beforeThumbnails: [SpatialThumbnail]
            var afterThumbnails: [SpatialThumbnail]
            var beforeBGRAThumbnails: [SpatialThumbnail]
            var afterBGRAThumbnails: [SpatialThumbnail]
        }
        try JSONEncoder().encode(Report(source: source.path,frames: [first,first+1],times: times,
            sourceThumbnails: thumbnails[0],beforeThumbnails: thumbnails[1],afterThumbnails: thumbnails[2],
            beforeBGRAThumbnails: quantized[0],afterBGRAThumbnails: quantized[1]))
            .write(to: URL(fileURLWithPath: args[5]))
        print("Rendered full-resolution frames",first,first+1,"without an output codec")
    }
}
