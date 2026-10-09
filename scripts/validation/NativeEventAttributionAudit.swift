// Native-resolution, pre-codec ordered counterfactual event attribution.
import Foundation
import AVFoundation
import CoreImage

@main struct NativeEventAttributionAudit {
    struct Cell: Codable {
        var sourceEV: Double; var globalGainEV: Double; var localContributionEV: Double
        var anchorContributionEV: Double; var totalGainEV: Double; var outputEV: Double
        var estimatorConfidence: Double; var darkFraction: Double; var clippedFraction: Double
        var sourceRGBEV: [Double]; var outputRGBEV: [Double]
        var neutralColourRGBEV: [Double]; var halfColourRGBEV: [Double]
    }
    struct Frame: Codable { var frame: Int; var time: Double; var cells: [Cell] }
    struct Report: Codable { var diagnostics: String; var source: String; var limitation: String; var frames: [Frame] }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 5 else { throw VideoError.message("Usage: source diagnostics frame-list output-folder") }
        let indices = args[3].split(separator:",").compactMap { Int($0) }
        guard !indices.isEmpty, indices.count == args[3].split(separator:",").count, indices.allSatisfy({$0 >= 0}) else { throw VideoError.message("Invalid frame indices") }
        let wanted = Set(indices), folder = URL(fileURLWithPath:args[2]), out = URL(fileURLWithPath:args[4])
        guard !FileManager.default.fileExists(atPath:out.path) else { throw VideoError.message("Output already exists") }
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let decoder = JSONDecoder()
        let fields = try decoder.decode([SpatialField].self,from:Data(contentsOf:folder.appendingPathComponent("spatial-fields.json")))
        let stops = try decoder.decode([Double].self,from:Data(contentsOf:folder.appendingPathComponent("global-stops.json")))
        guard wanted.allSatisfy({fields.indices.contains($0) && stops.indices.contains($0)}) else { throw VideoError.message("Missing retained fields") }
        let asset = AVURLAsset(url:URL(fileURLWithPath:args[1]))
        guard let track = try await asset.loadTracks(withMediaType:.video).first else { throw VideoError.message("No video") }
        let preferred = try await track.load(.preferredTransform), size = try await track.load(.naturalSize)
        let transform = VideoGeometry.coreImageTransform(preferred:preferred,naturalSize:size)
        let reader = try AVAssetReader(asset:asset)
        let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        reader.add(output);guard reader.startReading() else { throw reader.error ?? VideoError.message("Decode failed") }
        defer { reader.cancelReading() }
        let linear = CGColorSpace(name:CGColorSpace.linearSRGB)!, display = CGColorSpace(name:CGColorSpace.sRGB)!
        let context = CIContext(options:[.workingColorSpace:linear,.workingFormat:CIFormat.RGBAh.rawValue,.cacheIntermediates:false])
        func measure(_ image: CIImage) -> (levels:[Double],dark:[Double],clipped:[Double],rgb:[[Double]]) {
            let w = Int(image.extent.width), h = Int(image.extent.height)
            var rgba = [Float](repeating:0,count:w*h*4)
            rgba.withUnsafeMutableBytes { context.render(image,toBitmap:$0.baseAddress!,rowBytes:w*16,bounds:image.extent,format:.RGBAf,colorSpace:linear) }
            var sums = [Double](repeating:0,count:336), counts = sums, dark = sums, clipped = sums
            var channels = [[Double]](repeating:[0,0,0],count:336)
            for y in 0..<h { for x in 0..<w {
                let p = (y*w+x)*4, c = min(13,y*14/h)*24+min(23,x*24/w)
                let r = Double(rgba[p]),g = Double(rgba[p+1]),b = Double(rgba[p+2])
                let light = max(0,0.2126*r+0.7152*g+0.0722*b)
                sums[c] += light; counts[c] += 1
                channels[c][0] += max(0,r);channels[c][1] += max(0,g);channels[c][2] += max(0,b)
                if light < 0.003 { dark[c] += 1 }; if max(r,max(g,b)) >= 0.995 { clipped[c] += 1 }
            } }
            return (sums.indices.map { log2(max(1e-9,sums[$0]/max(1,counts[$0]))) },dark.indices.map {dark[$0]/max(1,counts[$0])},clipped.indices.map {clipped[$0]/max(1,counts[$0])},channels.indices.map { p in channels[p].map {log2(max(1e-9,$0/max(1,counts[p])))} })
        }
        func save(_ image: CIImage,_ name: String) throws {
            let e = image.extent, normalized = image.transformed(by:CGAffineTransform(translationX:-e.minX,y:-e.minY))
            let small = normalized.applyingFilter("CILanczosScaleTransform",parameters:[kCIInputScaleKey:960/e.width,kCIInputAspectRatioKey:1])
            try context.writePNGRepresentation(of:small,to:out.appendingPathComponent(name),format:.RGBA8,colorSpace:display)
        }
        var frames:[Frame] = [], index = 0
        while let sample = output.copyNextSampleBuffer() {
            if wanted.contains(index) {
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw VideoError.message("Missing pixels") }
                try autoreleasepool {
                    let image = CIImage(cvPixelBuffer:buffer).transformed(by:transform)
                    var local = fields[index];local.brightnessEV = nil;local.validationStops = nil
                    let global = SpatialRenderer.render(image,global:stops[index],field:SpatialField())
                    let spatial = SpatialRenderer.render(image,global:stops[index],field:local)
                    let full = SpatialRenderer.render(image,global:stops[index],field:fields[index])
                    func colourField(_ amount: Double) -> SpatialField {
                        var field = fields[index]
                        if let map = field.surface {
                            field.surface = .init(width:map.width,height:map.height,
                                channelEV:SurfaceLighting.colourAdjustedGains(map.channelEV,guide:map.guide,amount:amount),guide:map.guide,rowModel:map.rowModel)
                        }
                        return field
                    }
                    let neutral = SpatialRenderer.render(image,global:stops[index],field:colourField(0))
                    let half = SpatialRenderer.render(image,global:stops[index],field:colourField(0.5))
                    let s = measure(image),g = measure(global).levels,l = measure(spatial).levels,f = measure(full),n = measure(neutral),h = measure(half)
                    let cells = s.levels.indices.map { p in Cell(sourceEV:s.levels[p],globalGainEV:g[p]-s.levels[p],localContributionEV:l[p]-g[p],anchorContributionEV:f.levels[p]-l[p],totalGainEV:f.levels[p]-s.levels[p],outputEV:f.levels[p],estimatorConfidence:fields[index].confidence[p],darkFraction:s.dark[p],clippedFraction:s.clipped[p],sourceRGBEV:s.rgb[p],outputRGBEV:f.rgb[p],neutralColourRGBEV:n.rgb[p],halfColourRGBEV:h.rgb[p]) }
                    frames.append(Frame(frame:index,time:CMSampleBufferGetPresentationTimeStamp(sample).seconds,cells:cells))
                    try save(image,"\(index)-source.png");try save(full,"\(index)-corrected.png")
                    try save(neutral,"\(index)-neutral-colour.png");try save(half,"\(index)-half-colour.png")
                    try save(SpatialRenderer.render(image,global:stops[index],field:fields[index],diagnostic:.field),"\(index)-gain.png")
                }
                print("Measured native frame",index)
            }
            if index >= wanted.max()! { break };index += 1
        }
        guard frames.count == wanted.count else { throw reader.error ?? VideoError.message("Incomplete selected-frame decode") }
        let report = Report(diagnostics:folder.path,source:args[1],limitation:"Native-resolution Core Image render measured before encoding; PNGs are reduced for viewing. Fixed 24×14 image cells are not surface tracks. Ordered counterfactuals do not refit stages; anchor removal also removes affine-path conditional tone limiting. Colour ablations reproject the final field with the existing colour helper; they do not reproduce a complete slider refit. Dark/clipped fractions are source validity diagnostics, not illumination certainty.",frames:frames)
        let encoder = JSONEncoder();encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(report).write(to:out.appendingPathComponent("attribution.json"),options:.withoutOverwriting)
    }
}
