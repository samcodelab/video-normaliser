import Foundation
import AVFoundation
@main struct MakeLong {
 static func main() async throws {
  let source = AVURLAsset(url:URL(fileURLWithPath:CommandLine.arguments[1]))
  let track = try await source.loadTracks(withMediaType:.video)[0]
  let duration = try await track.load(.timeRange).duration
  let result = AVMutableComposition()
  let video = result.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!
  video.preferredTransform = try await track.load(.preferredTransform)
  let total = CMTime(seconds:600,preferredTimescale:2500)
  var cursor = CMTime.zero
  while cursor < total {
   let length = CMTimeMinimum(duration,total-cursor)
   try video.insertTimeRange(CMTimeRange(start:.zero,duration:length),of:track,at:cursor)
   cursor = cursor+length
  }
  let export = AVAssetExportSession(asset:result,presetName:AVAssetExportPresetPassthrough)!
  export.outputURL = URL(fileURLWithPath:CommandLine.arguments[2]);export.outputFileType = .mov
  await export.export()
  guard export.status == .completed else { throw export.error! }
  print("Generated 600-second repeated-source frame-count stress clip")
 }
}
