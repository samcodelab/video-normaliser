// General native analysis, preview and export-integrity audit.
import Foundation
import AVFoundation
import CoreImage
import AppKit
import ImageIO
import UniformTypeIdentifiers
@main struct PracticeAudit {
 static func main() async throws {
  let args = CommandLine.arguments
  guard args.count >= 3 else {
   throw NSError(domain: "Practice", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: audit source.mov output-directory [--export]"])
  }
  let source = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
  try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  let info = try await VideoEngine.info(for: AVURLAsset(url: source))
  let begin = Date()
  let analysis = try await VideoEngine.analyse(url: source, region: nil, progress: { _ in })
  let settings = Dictionary(uniqueKeysWithValues: SceneMath.scenes(samples: analysis.samples, boundaries: SceneMath.boundaries(in: analysis.samples), duration: info.duration).map { ($0.startFrame, SceneSettings()) })
  let calc = await SceneCorrection.calculateAsync(base: analysis.samples, boundaries: SceneMath.boundaries(in: analysis.samples), settings: settings, references: [:], cache: [:])
  print("INPUT", source.lastPathComponent, info.width, info.height, "duration", info.duration, "fps", info.fps, "frames", analysis.samples.count, "cuts", analysis.cuts, "analyse+correct seconds", Date().timeIntervalSince(begin))
  print("BOUNDARIES", SceneMath.boundaries(in: analysis.samples).sorted())
  let count = 8, width = 960, rowHeight = Int(Double(width/2)*Double(info.height)/Double(info.width))
  let context = CGContext(data: nil, width: width, height: rowHeight*count, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  for row in 0..<count {
   let index = min(analysis.samples.count-1, row*analysis.samples.count/count)
   let image = try await VideoEngine.preview(url: source, time: analysis.samples[index].time, curve: calc.curve, comparisonSize: CGSize(width: info.width, height: info.height), frameEnd: index+1<analysis.samples.count ? analysis.samples[index+1].time : info.duration)
   context.draw(image, in: CGRect(x:0,y:(count-1-row)*rowHeight,width:width,height:rowHeight))
  }
  let destination = CGImageDestinationCreateWithURL(out.appendingPathComponent("comparison.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination,context.makeImage()!,nil);CGImageDestinationFinalize(destination)
  if args.contains("--export") {
   let output = out.appendingPathComponent("corrected.mp4")
   try await VideoEngine.export(asset: AVURLAsset(url:source), curve:calc.curve, destination:output, progress:{_ in})
   let check = try await VideoEngine.analyse(url:output, region:nil,progress:{_ in})
   let resultInfo = try await VideoEngine.info(for:AVURLAsset(url:output))
   guard check.samples.count == analysis.samples.count, resultInfo.width == info.width, resultInfo.height == info.height, abs(resultInfo.duration-info.duration)<0.05 else { throw VideoError.message("Export did not preserve frames, dimensions or duration") }
   print("EXPORT VERIFIED",check.samples.count,"frames",resultInfo.duration,"seconds")
  }
 }
}
