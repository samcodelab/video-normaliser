// Export an immutable retained field using actual decoded source PTS.
import Foundation
import AVFoundation

@main struct ExportRetainedFields {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {throw VideoError.message("Usage: source diagnostics fresh-output.mp4")}
        let asset = AVURLAsset(url:URL(fileURLWithPath:args[1])),folder = URL(fileURLWithPath:args[2]),out = URL(fileURLWithPath:args[3]),decoder = JSONDecoder()
        guard !FileManager.default.fileExists(atPath:out.path) else {throw VideoError.message("Output exists")}
        let fields = try decoder.decode([SpatialField].self,from:Data(contentsOf:folder.appendingPathComponent("spatial-fields.json")))
        let stops = try decoder.decode([Double].self,from:Data(contentsOf:folder.appendingPathComponent("global-stops.json")))
        guard let track = try await asset.loadTracks(withMediaType:.video).first else {throw VideoError.message("No video")}
        let reader = try AVAssetReader(asset:asset),output = AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        reader.add(output);guard reader.startReading() else {throw VideoError.message("Decode failed")}
        var times:[Double] = []
        while let sample = output.copyNextSampleBuffer() {times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)}
        guard reader.status == .completed,fields.count == stops.count,times.count == fields.count,
              zip(times,times.dropFirst()).allSatisfy({$0 < $1}) else {throw VideoError.message("Decoded source PTS mismatch")}
        reader.cancelReading()
        try await VideoEngine.export(asset:asset,curve:.init(times:times,stops:stops,spatial:fields),destination:out,progress:{_ in})
        print("EXPORTED_RETAINED",times.count,out.path)
    }
}
