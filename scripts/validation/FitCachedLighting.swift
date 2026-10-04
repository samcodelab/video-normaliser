import Foundation
@main struct FitSpatial {
 static func main() throws {
  guard CommandLine.arguments.count == 3 else { fatalError("Usage: fit-cached <cache directory> <output prefix>") }
  let root=URL(fileURLWithPath:CommandLine.arguments[1])
  let thumbs=try JSONDecoder().decode([SpatialThumbnail].self,from:Data(contentsOf:root.appendingPathComponent("current-thumbnails.json")))
  let obj=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("current-analysis.json"))) as! [String:Any]
  let cells=obj["cells"] as! [[Double]]
  let cuts:Set<Int>=[11,18,38,50]
  let samples=thumbs.indices.map { ExposureSample(time:Double($0)/12,level:0,segment:0,cells:cells[$0],thumbnail:thumbs[$0]) }
  let assigned=SceneMath.assign(samples,boundaries:cuts)
  let start=Date()
  let curve=SceneCorrection.curve(base:assigned,boundaries:cuts,settings:[:],references:[:])
  try JSONEncoder().encode(curve.spatial).write(to:root.appendingPathComponent(CommandLine.arguments[2]+"-fields.json"))
  try JSONEncoder().encode(curve.stops).write(to:root.appendingPathComponent(CommandLine.arguments[2]+"-global.json"))
  print("Fitted \(curve.spatial.count) frames in \(Date().timeIntervalSince(start)) seconds")
 }
}
