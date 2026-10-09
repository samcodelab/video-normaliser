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
  func option(_ name: String) throws -> String? {
   guard let index = args.firstIndex(of: name) else { return nil }
   guard index+1 < args.count, !args[index+1].hasPrefix("--") else { throw VideoError.message("Missing value for \(name)") }
   return args[index+1]
  }
  let radiusText = try option("--radius") ?? "0.5"
  guard let radius = Double(radiusText), radius.isFinite, (0.1...3).contains(radius) else { throw VideoError.message("Radius must be 0.1–3 seconds") }
  let spatialText = try option("--spatial-strength") ?? "1"
  guard let spatialAmount = Double(spatialText), spatialAmount.isFinite, (0...1).contains(spatialAmount) else { throw VideoError.message("Spatial strength must be 0–1") }
  func unitAmount(_ name: String) throws -> Double {
   let text = try option(name) ?? "1"
   guard let value = Double(text),value.isFinite,(0...1).contains(value) else { throw VideoError.message("\(name) must be 0–1") }
   return value
  }
  let strength = try unitAmount("--strength"),colour = try unitAmount("--colour-strength")
  try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
  let info = try await VideoEngine.info(for: AVURLAsset(url: source))
  let begin = Date()
  let analysis = try await VideoEngine.analyse(url: source, region: nil, progress: { _ in })
  try JSONEncoder().encode(analysis.samples.map(\.cells)).write(to: out.appendingPathComponent("source-cells.json"))
  let settings = Dictionary(uniqueKeysWithValues: SceneMath.scenes(samples: analysis.samples, boundaries: SceneMath.boundaries(in: analysis.samples), duration: info.duration).map { ($0.startFrame, SceneSettings(strength: strength, radius: radius, mode: args.contains("--steady") ? .steady : .smooth, spatialStrength: args.contains("--global-only") ? 0 : spatialAmount, colourStrength: colour, preserveBrightness: !args.contains("--no-preserve"))) })
  try JSONEncoder().encode(settings).write(to: out.appendingPathComponent("settings.json"))
  if args.contains("--patch-check") {
   for scene in SceneMath.scenes(samples: analysis.samples, boundaries: SceneMath.boundaries(in: analysis.samples), duration: info.duration) {
    let shot = Array(analysis.samples[scene.startFrame..<(scene.startFrame+scene.frameCount)])
    for tracked in [false,true] {
     let measure = PatchExposure(cells: shot.map(\.cells), thumbnails: tracked ? shot.map(\.thumbnail) : [])
     let diagnostics = measure.diagnostics(times: shot.map(\.time), radius: 0.5, strength: 1, mode: .smooth)
     print("PATCH",scene.startFrame,tracked,measure.reliable,measure.values.first?.count ?? 0, diagnostics.map(\.appliedEV),diagnostics.compactMap(\.rejectionReason))
    }
   }
  }
  let calc = await SceneCorrection.calculateAsync(base: analysis.samples, boundaries: SceneMath.boundaries(in: analysis.samples), settings: settings, references: [:], cache: [:])
  if args.contains("--diagnostics") {
   try JSONEncoder().encode(analysis.samples.compactMap(\.thumbnail)).write(to: out.appendingPathComponent("thumbnails.json"))
   try JSONEncoder().encode(calc.curve.stops).write(to: out.appendingPathComponent("global-stops.json"))
   try JSONEncoder().encode(calc.curve.spatial).write(to: out.appendingPathComponent("spatial-fields.json"))
  }
  print("INPUT", source.lastPathComponent, info.width, info.height, "duration", info.duration, "fps", info.fps, "frames", analysis.samples.count, "cuts", analysis.cuts, "analyse+correct seconds", Date().timeIntervalSince(begin))
  print("SETTINGS", settings[0]?.mode.rawValue ?? "unknown", "radius", settings[0]?.radius ?? 0)
  print("BOUNDARIES", SceneMath.boundaries(in: analysis.samples).sorted())
  let reviewText = try option("--review-frames")
  let indices: [Int]
  if let reviewText {
   let tokens = reviewText.split(separator: ",")
   let parsed = tokens.compactMap { Int($0) }
   guard !parsed.isEmpty, parsed.count == tokens.count, parsed.allSatisfy({ analysis.samples.indices.contains($0) }) else { throw VideoError.message("Review frames must be valid zero-based source indices") }
   indices = parsed
  } else { indices = (0..<8).map { min(analysis.samples.count-1,$0*analysis.samples.count/8) } }
  try JSONEncoder().encode(indices).write(to: out.appendingPathComponent("review-frames.json"))
  let count = indices.count, width = 960, rowHeight = Int(Double(width/2)*Double(info.height)/Double(info.width))
  let context = CGContext(data: nil, width: width, height: rowHeight*count, bitsPerComponent: 8, bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  for row in 0..<count {
   let index = indices[row]
   let image = try await VideoEngine.preview(url: source, time: analysis.samples[index].time, curve: calc.curve, comparisonSize: CGSize(width: info.width, height: info.height), frameEnd: index+1<analysis.samples.count ? analysis.samples[index+1].time : info.duration)
   context.draw(image, in: CGRect(x:0,y:(count-1-row)*rowHeight,width:width,height:rowHeight))
  }
  let destination = CGImageDestinationCreateWithURL(out.appendingPathComponent("comparison.png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(destination,context.makeImage()!,nil);CGImageDestinationFinalize(destination)
  if args.contains("--export") {
   let output = out.appendingPathComponent("corrected.mp4")
   try await VideoEngine.export(asset: AVURLAsset(url:source), curve:calc.curve, destination:output, progress:{_ in})
   let check = try await VideoEngine.analyse(url:output, region:nil,progress:{_ in})
   try JSONEncoder().encode(check.samples.map(\.cells)).write(to: out.appendingPathComponent("corrected-cells.json"))
   struct BrightnessCheck: Codable {
    let startFrame: Int
    let sourceMedianEV: Double
    let outputMedianEV: Double
    let medianShiftEV: Double
    let adjacentRMSEV: Double
   }
   var brightnessChecks: [BrightnessCheck] = []
   struct RegionCheck: Codable {
    let startFrame: Int
    let region: Int
    let supportedFramePairs: Int
    let sourceAdjacentRMSEV: Double
    let outputAdjacentRMSEV: Double
    let outputPeakStepEV: Double
    let outputPeakFrame: Int
   }
   var regionChecks: [RegionCheck] = []
   for scene in SceneMath.scenes(samples: analysis.samples, boundaries: SceneMath.boundaries(in: analysis.samples), duration: info.duration) {
    let range = scene.startFrame..<(scene.startFrame+scene.frameCount)
    let shot = Array(analysis.samples[range])
    let patches = PatchExposure(cells: shot.map(\.cells), thumbnails: shot.map(\.thumbnail))
    guard patches.reliable else { continue }
    let after = range.enumerated().compactMap { patches.brightnessLevel(cells: check.samples[$0.element].cells, frame: $0.offset) }
    guard after.count == shot.count else { continue }
    let sourceRegions = shot.indices.map { patches.brightnessRegionLevels(cells: shot[$0].cells,frame: $0) }
    let outputRegions = range.enumerated().map { patches.brightnessRegionLevels(cells: check.samples[$0.element].cells,frame: $0.offset) }
    for region in 0..<12 {
     var sourceSteps: [Double] = [], outputSteps: [Double] = []
     var pairFrames: [Int] = []
     for i in 1..<shot.count {
      guard let a = sourceRegions[i-1][region],let b = sourceRegions[i][region],
            let c = outputRegions[i-1][region],let d = outputRegions[i][region] else { continue }
      sourceSteps.append(b-a);outputSteps.append(d-c);pairFrames.append(scene.startFrame+i)
     }
     if !outputSteps.isEmpty {
      regionChecks.append(RegionCheck(startFrame: scene.startFrame,region: region,supportedFramePairs: outputSteps.count,
       sourceAdjacentRMSEV: sqrt(sourceSteps.reduce(0) { $0+$1*$1 }/Double(sourceSteps.count)),
       outputAdjacentRMSEV: sqrt(outputSteps.reduce(0) { $0+$1*$1 }/Double(outputSteps.count)),
       outputPeakStepEV: outputSteps.map(abs).max() ?? 0,
       outputPeakFrame: pairFrames[outputSteps.indices.max(by: { abs(outputSteps[$0]) < abs(outputSteps[$1]) })!]))
     }
    }
    let beforeMedian = ExposureMath.median(patches.levels), afterMedian = ExposureMath.median(after)
    let changes = (1..<after.count).map { pow(after[$0]-after[$0-1],2) }
    brightnessChecks.append(BrightnessCheck(startFrame: scene.startFrame, sourceMedianEV: beforeMedian,
      outputMedianEV: afterMedian, medianShiftEV: afterMedian-beforeMedian, adjacentRMSEV: sqrt(changes.reduce(0,+)/Double(max(1,changes.count)))))
   }
   try JSONEncoder().encode(brightnessChecks).write(to: out.appendingPathComponent("brightness-check.json"))
   try JSONEncoder().encode(regionChecks).write(to: out.appendingPathComponent("regional-brightness-check.json"))
   let resultInfo = try await VideoEngine.info(for:AVURLAsset(url:output))
   guard check.samples.count == analysis.samples.count, resultInfo.width == info.width, resultInfo.height == info.height, abs(resultInfo.duration-info.duration)<0.05 else { throw VideoError.message("Export did not preserve frames, dimensions or duration") }
   print("EXPORT VERIFIED",check.samples.count,"frames",resultInfo.duration,"seconds")
  }
 }
}
