// Apply only the new refinement to immutable retained fields, without refitting.
import Foundation
import AVFoundation

@main struct QuietColourFieldAudit {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 || (args.count == 6 && args[4] == "--export-source"),let fps = Double(args[2]),fps.isFinite,fps > 0 else {
            throw VideoError.message("Usage: diagnostics fps output-folder [--export-source source.mov]")
        }
        let input = URL(fileURLWithPath:args[1]),out = URL(fileURLWithPath:args[3]),decoder = JSONDecoder()
        guard !FileManager.default.fileExists(atPath:out.path) else {throw VideoError.message("Output exists")}
        func read<T:Decodable>(_ name:String,_ type:T.Type) throws -> T {try decoder.decode(type,from:Data(contentsOf:input.appendingPathComponent(name)))}
        let images = try read("thumbnails.json",[SpatialThumbnail].self),fields = try read("spatial-fields.json",[SpatialField].self),stops = try read("global-stops.json",[Double].self)
        let settings = try read("settings.json",[Int:SceneSettings].self)
        guard images.count == fields.count,images.count == stops.count,settings.keys.min() == 0 else {throw VideoError.message("Invalid retained diagnostics")}
        var times = images.indices.map {Double($0)/fps}
        if args.count == 6 {
            let asset = AVURLAsset(url:URL(fileURLWithPath:args[5]))
            guard let track = try await asset.loadTracks(withMediaType:.video).first else {throw VideoError.message("No source video")}
            let reader = try AVAssetReader(asset:asset)
            let output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            reader.add(output);guard reader.startReading() else {throw reader.error ?? VideoError.message("Decode failed")}
            defer {reader.cancelReading()}
            times = []
            while let sample = output.copyNextSampleBuffer() {times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)}
            guard reader.status == .completed,times.count == images.count,times.allSatisfy(\.isFinite),zip(times,times.dropFirst()).allSatisfy({$0 < $1}) else {throw VideoError.message("Source timing does not match retained frames")}
        }
        var result = fields
        let starts = settings.keys.sorted()
        for (index,start) in starts.enumerated() {
            let end = index+1 < starts.count ? starts[index+1] : images.count
            guard start >= 0,start < end,end <= images.count else {throw VideoError.message("Invalid scene range")}
            let samples = (start..<end).map {ExposureSample(time:times[$0],level:0,segment:0,thumbnail:images[$0])}
            let refined = QuietColourContinuity.apply(samples:samples,stops:Array(stops[start..<end]),fields:Array(fields[start..<end]),options:settings[start]!)
            result.replaceSubrange(start..<end,with:refined)
        }
        let changed = fields.indices.filter {fields[$0].surface?.channelEV != result[$0].surface?.channelEV}
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let encoder = JSONEncoder()
        try encoder.encode(result).write(to:out.appendingPathComponent("spatial-fields.json"))
        for file in ["global-stops.json","thumbnails.json","settings.json"] {try FileManager.default.copyItem(at:input.appendingPathComponent(file),to:out.appendingPathComponent(file))}
        try JSONSerialization.data(withJSONObject:["changedFrames":changed,"input":input.path,"limitation":"Refinement-only comparison using retained correction fields; no baseline re-analysis or user-slider refit. Non-export runs use explicitly supplied nominal CFR timing."],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("review.json"))
        if args.count == 6,!changed.isEmpty {
            try await VideoEngine.export(asset:AVURLAsset(url:URL(fileURLWithPath:args[5])),curve:.init(times:times,stops:stops,spatial:result),destination:out.appendingPathComponent("corrected.mp4"),progress:{_ in})
        }
        print("REFINEMENT",input.path,"changedFrames",changed.count)
    }
}
