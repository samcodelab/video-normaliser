// Clip-specific audit: reviewed cuts and measurement regions for the 86-frame fixture.
import Foundation
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main struct ConsistencyAudit {
 static func main() async throws {
  let args = CommandLine.arguments
  guard args.count >= 3 else { fatalError("Usage: audit <source movie> <output directory> [--export]") }
  let source = URL(fileURLWithPath: args[1])
  let root = URL(fileURLWithPath: args[2])
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let analysis = try await VideoEngine.analyse(url: source, region: nil, progress: { _ in })
  let curve = SceneCorrection.curve(base: analysis.samples, boundaries: [11,18,38,50], settings: [:], references: [:])
  try JSONEncoder().encode(analysis.samples.map { $0.thumbnail! }).write(to: root.appendingPathComponent("current-thumbnails.json"))
  try JSONSerialization.data(withJSONObject: ["cells": analysis.samples.map(\.cells), "stops": curve.stops]).write(to: root.appendingPathComponent("current-analysis.json"))
  try JSONEncoder().encode(curve.spatial).write(to: root.appendingPathComponent("fields.json"))
  let global = ExposureCurve(times: curve.times, stops: curve.stops)
  for i in [12,13,14] {
   for (name, correction) in [("source",ExposureCurve.empty),("global",global),("corrected",curve)] {
    let image = try await VideoEngine.preview(url: source, time: analysis.samples[i].time, curve: correction, frameEnd: analysis.samples[i+1].time)
    let output = CGImageDestinationCreateWithURL(root.appendingPathComponent("\(name)-\(i).png") as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(output,image,nil);CGImageDestinationFinalize(output)
   }
  }
  print("Preview audit complete: \(root.path)")
  if args.contains("--export") {
   try await VideoEngine.export(asset: AVURLAsset(url: source), curve: curve, destination: root.appendingPathComponent("candidate.mov"), progress: { _ in })
   print("Export complete")
  }
 }
}
