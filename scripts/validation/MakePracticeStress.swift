// Offline validation utility; generated lighting changes are synthetic.
import Foundation
import AVFoundation
import CoreImage
@main struct MakeStress {
 static func main() async throws {
  let args = CommandLine.arguments
  guard args.count == 4, ["global", "local"].contains(args[3]) else {
   throw NSError(domain: "Practice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: make-stress source.mov output.mov global|local"])
  }
  let asset = AVURLAsset(url:URL(fileURLWithPath:args[1]))
  let output = URL(fileURLWithPath:args[2]), style = args[3]
  guard let exporter = AVAssetExportSession(asset:asset,presetName:AVAssetExportPresetHighestQuality) else { throw NSError(domain:"Stress",code:1) }
  let composition = AVMutableVideoComposition(asset:asset,applyingCIFiltersWithHandler:{ request in
   let frame = Int((request.compositionTime.seconds*25).rounded())
   let source = request.sourceImage
   let globalEV = [0.0,-0.55,0.35,-0.25,0.50,-0.40,0.15,-0.10][(frame/2)%8]
   let changed: CIImage
   if style == "global" {
    changed = source.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:globalEV])
   } else {
    let phase = frame%75
    let ev = phase == 35 ? -0.8 : phase == 36 ? 0.65 : phase == 37 ? -0.25 : 0
    let centre = CIVector(x:source.extent.midX,y:source.extent.midY)
    let mask = CIFilter(name:"CIRadialGradient",parameters:["inputCenter":centre,"inputRadius0":source.extent.width*0.08,"inputRadius1":source.extent.width*0.42,"inputColor0":CIColor(red:1,green:1,blue:1),"inputColor1":CIColor(red:0,green:0,blue:0)])!.outputImage!.cropped(to:source.extent)
    let flash = source.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:ev]).applyingFilter("CIColorControls",parameters:[kCIInputContrastKey:ev == 0 ? 1 : 1.15])
    changed = flash.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:source,kCIInputMaskImageKey:mask]).cropped(to:source.extent)
   }
   request.finish(with:changed,context:nil)
  })
  exporter.videoComposition = composition
  exporter.outputURL = output; exporter.outputFileType = .mov
  await exporter.export()
  guard exporter.status == .completed else { throw exporter.error ?? NSError(domain:"Stress",code:2) }
  print("Generated",style,"stress copy",output.lastPathComponent)
 }
}
